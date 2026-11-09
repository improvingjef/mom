defmodule Mom.StatusTest do
  use ExUnit.Case, async: false

  alias Mom.Status

  @min 60_000
  @hour 60 * @min

  setup do
    start_supervised!(Status)
    Status.reset()
    :ok
  end

  test "state goes unknown -> down -> ok -> warn -> ok -> down" do
    t0 = 1_800_000_000_000
    :ok = Status.register("school")
    assert %{state: :unknown, connected: false} = Status.get("school", t0)

    :ok = Status.down("school", nil, t0)
    assert %{state: :down, down_since: ^t0} = Status.get("school", t0)

    # down_since keeps the first failure
    :ok = Status.down("school", nil, t0 + @min)
    assert %{down_since: ^t0} = Status.get("school", t0 + @min)

    :ok = Status.connected("school", %{"release" => "0.1.0"}, t0 + 2 * @min)

    assert %{state: :ok, connected_since: since, down_since: nil, info: %{"release" => "0.1.0"}} =
             Status.get("school", t0 + 2 * @min)

    assert since == t0 + 2 * @min

    :ok = Status.error("school", "error", "Postgrex timeout", t0 + 3 * @min)
    assert %{state: :warn, errors_1h: 1} = Status.get("school", t0 + 3 * @min)

    # one hour later the error no longer counts for warn, but stays in the 24 h list
    later = t0 + 3 * @min + @hour + 1
    assert %{state: :ok, errors_1h: 0, errors: [_]} = Status.get("school", later)

    :ok = Status.down("school", "gone", later)
    assert %{state: :down, connected: false, note: "gone"} = Status.get("school", later)
  end

  test "errors are kept for 24 h, newest first, at most 200" do
    t0 = 1_800_000_000_000
    :ok = Status.connected("latte", %{}, t0)

    for i <- 1..250, do: Status.error("latte", "error", "e#{i}", t0 + i)

    %{errors: errors, last_error: last} = Status.get("latte", t0 + 300)
    assert length(errors) == 200
    assert last.message == "e250"
    assert List.last(errors).message == "e51"

    # 24 h after the last one, nothing remains (read side)
    assert %{errors: [], state: :ok} = Status.get("latte", t0 + 250 + 24 * @hour + 1)

    # and the next write prunes the old ones
    :ok = Status.error("latte", "error", "fresh", t0 + 25 * @hour)
    assert %{errors: [%{message: "fresh"}]} = Status.get("latte", t0 + 25 * @hour)
  end

  test "error entries have kind, short message and a stable fingerprint" do
    t0 = 1_800_000_000_000
    :ok = Status.connected("x", %{}, t0)
    :ok = Status.error("x", "error", "  timeout after 5000ms on #PID<0.123.0>\nstack line", t0)
    :ok = Status.error("x", "error", "timeout after 15000ms on #PID<0.999.0>", t0 + 1)

    [b, a] = Status.get("x", t0 + 2).errors
    assert a.message == "timeout after 5000ms on #PID<0.123.0>"
    assert a.kind == "error"
    assert a.fingerprint == b.fingerprint
    assert byte_size(a.fingerprint) == 12
    refute Status.fingerprint("error", "a") == Status.fingerprint("warning", "a")
  end

  test "all/1 is sorted by name; event/3 sets last event" do
    :ok = Status.register("b")
    :ok = Status.register("a")
    :ok = Status.event("b", "vm.memory", 5)
    assert [%{name: "a"}, %{name: "b", last_event: %{at: 5, kind: "vm.memory"}}] = Status.all(10)
  end
end
