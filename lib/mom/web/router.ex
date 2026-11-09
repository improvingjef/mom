defmodule Mom.Web.Router do
  @moduledoc """
  The status endpoint.

    * `GET /health` - no token; `ok` (for the load balancer).
    * `GET /status` - one line per target; `?format=json` for JSON.
    * `GET /status/<target>` - recent errors of one target; `?format=json` too.

  `/status*` needs `Authorization: Bearer <token>` (see `Mom.Tokens`). A
  wrong or missing token gets 401; after `Mom.Tokens.failure_limit/0` failed
  attempts in a minute, an address gets 429 until the minute ends.

  The client address is the TCP peer, or, with `config :mom, :trust_proxy,
  true`, the last address in `X-Forwarded-For` (the one the load balancer
  added).
  """

  use Plug.Router

  alias Mom.{Status, Tokens}
  alias Mom.Web.Format

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_text(conn, 200, "ok\n")
  end

  get "/status" do
    with {:ok, conn} <- authorize(conn) do
      targets = Status.all()

      if json?(conn) do
        send_json(conn, 200, %{targets: Enum.map(targets, &Format.json(&1, false))})
      else
        send_text(conn, 200, Format.status_text(targets))
      end
    end
  end

  get "/status/:target" do
    with {:ok, conn} <- authorize(conn) do
      case Status.get(target) do
        nil ->
          send_text(conn, 404, "unknown target\n")

        t ->
          if json?(conn),
            do: send_json(conn, 200, Format.json(t, true)),
            else: send_text(conn, 200, Format.target_text(t))
      end
    end
  end

  match _ do
    send_text(conn, 404, "not found\n")
  end

  defp authorize(conn) do
    ip = client_ip(conn)

    if Tokens.blocked?(ip) do
      send_text(conn, 429, "too many failed attempts\n")
    else
      case Tokens.verify(bearer(conn)) do
        {:ok, name} ->
          {:ok, Plug.Conn.assign(conn, :token_name, name)}

        :error ->
          Tokens.record_failure(ip)

          conn
          |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
          |> send_text(401, "unauthorized\n")
      end
    end
  end

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  @doc false
  def client_ip(conn) do
    forwarded =
      if Application.get_env(:mom, :trust_proxy, false) do
        conn
        |> Plug.Conn.get_req_header("x-forwarded-for")
        |> Enum.join(",")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> List.last()
      end

    forwarded || conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp json?(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    conn.query_params["format"] == "json"
  end

  defp send_text(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
  end

  defp send_json(conn, status, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(data))
  end
end
