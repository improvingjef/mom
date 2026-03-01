defmodule Mom.Beam do
  @moduledoc false

  alias Mom.{Config, RemoteLoggerHandler, RemoteTelemetryHandler}

  @spec ensure_node_started(atom() | nil) :: :ok
  def ensure_node_started(nil), do: :ok

  def ensure_node_started(cookie) when is_atom(cookie) do
    Node.set_cookie(cookie)

    case Node.alive?() do
      true ->
        :ok

      false ->
        name = :"mom_#{System.unique_integer([:positive])}@127.0.0.1"
        {:ok, _} = :net_kernel.start([name])
        :ok
    end
  end

  @spec attach_logger(Config.t(), pid()) :: :ok
  def attach_logger(%Config{runtime: %{mode: :inproc, min_level: min_level}}, pid) do
    _ = :logger.remove_handler(:mom_handler)
    :logger.add_handler(:mom_handler, RemoteLoggerHandler, %{mom_pid: pid, min_level: min_level})
    :ok
  end

  def attach_logger(%Config{runtime: %{mode: :remote, node: node, min_level: min_level}}, pid) do
    {mod, bin, file} = :code.get_object_code(RemoteLoggerHandler)
    :rpc.call(node, :code, :load_binary, [mod, file, bin])
    _ = :rpc.call(node, :logger, :remove_handler, [:mom_handler])

    :rpc.call(node, :logger, :add_handler, [
      :mom_handler,
      RemoteLoggerHandler,
      %{mom_pid: pid, min_level: min_level}
    ])

    :ok
  end

  @spec attach_telemetry(Config.t(), pid()) :: :ok
  def attach_telemetry(%Config{runtime: %{mode: :inproc}}, _pid), do: :ok

  def attach_telemetry(%Config{runtime: %{mode: :remote, node: node}}, pid) do
    {mod, bin, file} = :code.get_object_code(RemoteTelemetryHandler)
    :rpc.call(node, :code, :load_binary, [mod, file, bin])
    :rpc.call(node, RemoteTelemetryHandler, :attach, [pid])
    :ok
  end

  @spec monitor_node(Config.t()) :: :ok
  def monitor_node(%Config{runtime: %{mode: :inproc}}), do: :ok

  def monitor_node(%Config{runtime: %{mode: :remote, node: node}}) do
    Node.monitor(node, true)
    :ok
  end
end
