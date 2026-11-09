defmodule Mom.TargetsPeerTest do
  @moduledoc """
  A watcher against a real second BEAM node (started with OTP's `:peer`):
  connects with a per-node cookie, reads `:mom_info`, records an error
  logged on the peer, marks the target down when the peer stops, and
  reconnects (handlers and info again) when the node comes back.
  """
  use ExUnit.Case, async: false

  alias Mom.Status
  alias Mom.Targets.Target
  alias Mom.Web.Format

  @moduletag :peer
  @target_cookie :mom_peer_test_target_cookie

  setup_all do
    started_here? =
      if Node.alive?() do
        false
      else
        epmd = System.find_executable("epmd") || Path.join(:code.root_dir(), "bin/epmd")
        {_, 0} = System.cmd(epmd, ["-daemon"])
        name = :"mom_test_#{System.unique_integer([:positive])}@127.0.0.1"
        {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
        true
      end

    # Mom's own cookie differs from the target's: the per-node cookie must be used.
    own_cookie = Node.get_cookie()
    Node.set_cookie(:mom_own_cookie_not_the_target)

    on_exit(fn ->
      Node.set_cookie(own_cookie)
      if started_here?, do: :net_kernel.stop()
    end)

    :ok
  end

  setup do
    start_supervised!(Status)
    Status.reset()
    :ok
  end

  defp start_peer(name, info) do
    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(@target_cookie)]
      })

    for {k, v} <- info, do: :ok = :peer.call(peer, :application, :set_env, [:mom_info, k, v])
    {peer, node}
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      truthy when truthy not in [nil, false] ->
        truthy

      _ when tries > 0 ->
        Process.sleep(50)
        eventually(fun, tries - 1)

      _ ->
        flunk("condition not met; status: #{inspect(Status.get("school"))}")
    end
  end

  defp pipeline_worker_config(sup) do
    [{_, watcher, _, _}] = Supervisor.which_children(sup)

    :sys.get_state(watcher).owned
    |> Enum.find_value(fn pid ->
      try do
        case :sys.get_state(pid, 200) do
          %{worker_opts: opts} -> opts[:config]
          _ -> nil
        end
      catch
        :exit, _ -> nil
      end
    end)
  end

  test "watcher connects, reads :mom_info, records errors, marks down, reconnects" do
    peer_name = :"school_#{System.unique_integer([:positive])}"

    {peer, node} =
      start_peer(peer_name,
        name: "school",
        repo: "improvingjef/school",
        env: "production",
        release: "0.1.0",
        commit: "4db6647deadbeef"
      )

    target = %Target{name: "school", node: node, cookie: @target_cookie, triage: :off}

    sup =
      start_supervised!(
        {Mom.Targets.Supervisor,
         name: :mom_peer_test_targets,
         targets: [target],
         backoff: {50, 200},
         config_opts: [poll_interval_ms: 50]}
      )

    # 1. connected, project info read
    eventually(fn -> Status.get("school").state == :ok end)
    status = Status.get("school")
    assert status.info["repo"] == "improvingjef/school"
    assert status.info["release"] == "0.1.0"
    assert status.connected_since

    # the info's repo is the repo the pipeline workers use for issues/fixes
    eventually(fn ->
      pipeline_worker_config(sup).governance.github_repo == "improvingjef/school"
    end)

    # 2. an error logged on the peer reaches the status (triage off: no agent)
    :ok = :peer.call(peer, :logger, :error, [~c"Postgrex timeout ~p", [42]])
    eventually(fn -> Status.get("school").errors_1h == 1 end)

    assert %{state: :warn, last_error: %{kind: "error", message: "Postgrex timeout 42"}} =
             Status.get("school")

    if System.get_env("MOM_PRINT_STATUS"), do: IO.puts("\n" <> Format.status_text(Status.all()))

    # 3. the peer stops: down
    :ok = :peer.stop(peer)
    eventually(fn -> Status.get("school").state == :down end)
    assert %{connected: false, down_since: down_since} = Status.get("school")
    assert down_since

    if System.get_env("MOM_PRINT_STATUS"), do: IO.puts(Format.status_text(Status.all()))

    # 4. the node comes back (new release): reconnect, info read again,
    #    handlers installed again
    {peer2, ^node} =
      start_peer(peer_name, release: "0.1.1", commit: "aaaaaaa1", repo: "improvingjef/school")

    on_exit(fn ->
      try do
        :peer.stop(peer2)
      catch
        :exit, _ -> :ok
      end
    end)

    eventually(fn -> Status.get("school").info["release"] == "0.1.1" end)
    assert Status.get("school").connected

    :ok = :peer.call(peer2, :logger, :error, [~c"second ~s", ["failure"]])
    eventually(fn -> length(Status.get("school").errors) == 2 end)
    assert Status.get("school").last_error.message == "second failure"
  end
end
