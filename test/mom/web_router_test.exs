defmodule Mom.Web.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Mom.{Status, Tokens}
  alias Mom.Web.Router

  setup do
    dir = Path.join(System.tmp_dir!(), "mom-router-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    start_supervised!(Status)
    start_supervised!({Tokens, data_dir: dir})
    Status.reset()
    :ets.delete_all_objects(:mom_auth_failures)
    Application.delete_env(:mom, :trust_proxy)
    on_exit(fn -> Application.delete_env(:mom, :trust_proxy) end)
    {:ok, token} = Tokens.new("test-agent")
    {:ok, token: token}
  end

  defp call(path, token \\ nil, headers \\ []) do
    conn = conn(:get, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Router.call(conn, Router.init([]))
  end

  defp hhmm(ms), do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M")

  defp seed do
    now = Status.now_ms()

    :ok =
      Status.connected("school", %{"release" => "0.1.0", "commit" => "4db6647e1"}, now - 600_000)

    :ok =
      Status.connected(
        "latte",
        %{"release" => "0.1.0", "commit" => "9f2c1aa00", "repo" => "improvingjef/latte"},
        now - 600_000
      )

    for msg <- ["DBConnection error", "Postgrex timeout 1", "Postgrex timeout"],
        do: :ok = Status.error("latte", "error", msg, now - 60_000)

    :ok = Status.down("revivehub", nil, now - 120_000)
    now
  end

  test "GET /health needs no token" do
    conn = call("/health")
    assert conn.status == 200
    assert conn.resp_body == "ok\n"
  end

  test "GET /status without or with a wrong token is 401", %{token: token} do
    assert call("/status").status == 401
    assert call("/status", token <> "x").status == 401
    assert call("/status/school").status == 401
    conn = call("/status", "nope")
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
  end

  test "GET /status text: one line per target", %{token: token} do
    now = seed()
    conn = call("/status", token)
    assert conn.status == 200
    assert hd(get_resp_header(conn, "content-type")) =~ "text/plain"

    expected =
      """
      latte      warn  0.1.0 9f2c1aa  errors 1h: 3  last #{hhmm(now - 60_000)} Postgrex timeout
      revivehub  down                 connected: no since #{hhmm(now - 120_000)}
      school     ok    0.1.0 4db6647  errors 1h: 0
      """

    assert conn.resp_body == expected
    if System.get_env("MOM_PRINT_STATUS"), do: IO.puts("\n" <> conn.resp_body)
  end

  test "GET /status?format=json", %{token: token} do
    seed()
    conn = call("/status?format=json", token)
    assert conn.status == 200
    %{"targets" => [latte, revive, school]} = Jason.decode!(conn.resp_body)

    assert %{
             "name" => "latte",
             "state" => "warn",
             "errors_1h" => 3,
             "info" => %{"repo" => "improvingjef/latte"}
           } = latte

    assert latte["last_error"]["message"] == "Postgrex timeout"
    refute Map.has_key?(latte, "errors")
    assert %{"name" => "revivehub", "state" => "down", "connected" => false} = revive
    assert %{"name" => "school", "state" => "ok"} = school
  end

  test "GET /status/<target> lists recent errors; unknown target is 404", %{token: token} do
    seed()
    conn = call("/status/latte", token)
    assert conn.status == 200
    [head | lines] = String.split(conn.resp_body, "\n", trim: true)

    assert head =~
             "latte  warn  commit=9f2c1aa00 release=0.1.0 repo=improvingjef/latte  connected since"

    assert head =~ "errors 24h: 3"
    assert length(lines) == 3

    assert hd(lines) =~
             ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ  error  [0-9a-f]{12}  Postgrex timeout$/

    json = call("/status/latte?format=json", token) |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert length(json["errors"]) == 3

    assert call("/status/nope", token).status == 404
  end

  test "10 failed attempts a minute from one address get 429, even with a good token", %{
    token: token
  } do
    for _ <- 1..10, do: assert(call("/status", "bad").status == 401)
    assert call("/status", token).status == 429
    assert call("/health").status == 200
  end

  test "X-Forwarded-For is used only when the proxy is trusted", %{token: token} do
    xff = [{"x-forwarded-for", "1.2.3.4, 10.0.0.9"}]
    for _ <- 1..10, do: call("/status", "bad", xff)

    # not trusted: all failures counted on the TCP peer (127.0.0.1)
    assert call("/status", token, [{"x-forwarded-for", "5.5.5.5"}]).status == 429

    :ets.delete_all_objects(:mom_auth_failures)
    Application.put_env(:mom, :trust_proxy, true)
    for _ <- 1..10, do: call("/status", "bad", xff)
    # the last hop (10.0.0.9) is blocked, others are not
    assert call("/status", token, [{"x-forwarded-for", "1.2.3.4, 10.0.0.9"}]).status == 429
    assert call("/status", token, [{"x-forwarded-for", "10.0.0.9, 10.0.0.7"}]).status == 200
  end
end
