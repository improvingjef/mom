defmodule Mom.Tokens do
  @moduledoc """
  Bearer tokens for the status endpoint.

  `new/1` returns the token text once. Only the SHA-256 hash of the token is
  kept, with its name and creation time, in `tokens.json` under the data
  directory. Writes go to a temporary file first and then replace the old
  file with a rename, so a crash never leaves a half-written file.

  On the Mom server:

      bin/mom rpc '{:ok, t} = Mom.Tokens.new("claude-loop"); IO.puts(t)'
      bin/mom rpc 'Mom.Tokens.revoke("claude-loop") |> IO.inspect()'
      bin/mom rpc 'Mom.Tokens.list() |> IO.inspect()'

  The process also owns the table that limits failed attempts per remote
  address (`failure_limit/0` per minute).
  """

  use GenServer

  require Logger

  @file_name "tokens.json"
  @failures_table :mom_auth_failures
  @failure_limit 10
  @failure_window_ms 60_000

  @type entry :: %{name: String.t(), hash: String.t(), created_at: String.t()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Makes a token for `name`. Returns the token text; it is not stored."
  @spec new(String.t()) :: {:ok, String.t()} | {:error, :exists | :invalid_name | term()}
  def new(name), do: GenServer.call(__MODULE__, {:new, name})

  @doc "Removes the token of `name`."
  @spec revoke(String.t()) :: :ok | {:error, :not_found | term()}
  def revoke(name), do: GenServer.call(__MODULE__, {:revoke, name})

  @doc "Names and creation times; never the hashes."
  @spec list() :: [%{name: String.t(), created_at: String.t()}]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc """
  Checks a presented token. Compares its hash with every stored hash in
  constant time (all entries are compared, no early exit).
  """
  @spec verify(String.t() | nil) :: {:ok, String.t()} | :error
  def verify(token) when is_binary(token) and token != "" do
    GenServer.call(__MODULE__, {:verify, hash(token)})
  end

  def verify(_), do: :error

  @spec failure_limit() :: pos_integer()
  def failure_limit, do: @failure_limit

  @doc "True when `ip` has reached the failed-attempt limit in the current minute."
  @spec blocked?(String.t(), integer()) :: boolean()
  def blocked?(ip, now \\ System.system_time(:millisecond)) do
    case lookup_failures(ip, now) do
      count when count >= @failure_limit -> true
      _ -> false
    end
  end

  @doc "Counts one failed attempt from `ip`."
  @spec record_failure(String.t(), integer()) :: :ok
  def record_failure(ip, now \\ System.system_time(:millisecond)) do
    if :ets.whereis(@failures_table) != :undefined do
      key = {ip, div(now, @failure_window_ms)}
      :ets.update_counter(@failures_table, key, 1, {key, 0})
      prune_failures(now)
    end

    :ok
  end

  @doc false
  def hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  # --- server ---

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir) || Mom.data_dir()
    path = Path.join(data_dir, @file_name)

    if :ets.whereis(@failures_table) == :undefined do
      :ets.new(@failures_table, [:named_table, :public, :set])
    end

    case read_file(path) do
      {:ok, entries} ->
        {:ok, %{path: path, entries: entries}}

      {:error, reason} ->
        {:stop, {:tokens_file, path, reason}}
    end
  end

  @impl true
  def handle_call({:new, name}, _from, state) do
    cond do
      not valid_name?(name) ->
        {:reply, {:error, :invalid_name}, state}

      Enum.any?(state.entries, &(&1.name == name)) ->
        {:reply, {:error, :exists}, state}

      true ->
        token = "mom_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        entry = %{
          name: name,
          hash: hash(token),
          created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        }

        entries = state.entries ++ [entry]

        case write_file(state.path, entries) do
          :ok ->
            Logger.info("mom: token created for #{name}")
            {:reply, {:ok, token}, %{state | entries: entries}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:revoke, name}, _from, state) do
    case Enum.split_with(state.entries, &(&1.name == name)) do
      {[], _} ->
        {:reply, {:error, :not_found}, state}

      {_, entries} ->
        case write_file(state.path, entries) do
          :ok ->
            Logger.info("mom: token revoked for #{name}")
            {:reply, :ok, %{state | entries: entries}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.map(state.entries, &Map.take(&1, [:name, :created_at])), state}
  end

  def handle_call({:verify, presented}, _from, state) do
    match =
      Enum.reduce(state.entries, nil, fn entry, found ->
        equal? = Plug.Crypto.secure_compare(entry.hash, presented)
        if equal? and is_nil(found), do: entry.name, else: found
      end)

    {:reply, if(match, do: {:ok, match}, else: :error), state}
  end

  # --- helpers ---

  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[A-Za-z0-9._-]{1,64}$/, name)

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} ->
        with {:ok, list} when is_list(list) <- Jason.decode(body) do
          {:ok,
           Enum.map(list, fn m ->
             %{name: m["name"], hash: m["hash"], created_at: m["created_at"]}
           end)}
        else
          _ -> {:error, :invalid_json}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_file(path, entries) do
    dir = Path.dirname(path)
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, Jason.encode_to_iodata!(entries, pretty: true)),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp lookup_failures(ip, now) do
    if :ets.whereis(@failures_table) == :undefined do
      0
    else
      case :ets.lookup(@failures_table, {ip, div(now, @failure_window_ms)}) do
        [{_, count}] -> count
        [] -> 0
      end
    end
  end

  defp prune_failures(now) do
    current = div(now, @failure_window_ms)
    :ets.select_delete(@failures_table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
  end
end
