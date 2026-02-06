defmodule Mom.LLM.API do
  @moduledoc false

  alias Mom.Config

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @openai_url "https://api.openai.com/v1/chat/completions"

  @spec call_anthropic(String.t(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def call_anthropic(prompt, %Config{llm_api_key: key} = config) when is_binary(key) do
    url = config.llm_api_url || @anthropic_url
    model = config.llm_model || "claude-3-7-sonnet-latest"

    payload = %{
      "model" => model,
      "max_tokens" => 2048,
      "messages" => [
        %{"role" => "user", "content" => prompt}
      ]
    }

    headers = [
      {~c"x-api-key", to_charlist(key)},
      {~c"anthropic-version", ~c"2023-06-01"}
    ]

    request(url, headers, payload, fn body ->
      with {:ok, data} <- Jason.decode(body),
           content when is_list(content) <- data["content"],
           [%{"text" => text} | _] <- content do
        {:ok, text}
      else
        _ -> {:error, :invalid_anthropic_response}
      end
    end)
  end

  def call_anthropic(_prompt, _config), do: {:error, "llm_api_key is required"}

  @spec call_openai(String.t(), Config.t()) :: {:ok, String.t()} | {:error, term()}
  def call_openai(prompt, %Config{llm_api_key: key} = config) when is_binary(key) do
    url = config.llm_api_url || @openai_url
    model = config.llm_model || "gpt-4.1-mini"

    payload = %{
      "model" => model,
      "messages" => [
        %{"role" => "user", "content" => prompt}
      ],
      "temperature" => 0.2
    }

    headers = [
      {~c"authorization", ~c"Bearer " ++ to_charlist(key)}
    ]

    request(url, headers, payload, fn body ->
      with {:ok, data} <- Jason.decode(body),
           [%{"message" => %{"content" => text}} | _] <- data["choices"] do
        {:ok, text}
      else
        _ -> {:error, :invalid_openai_response}
      end
    end)
  end

  def call_openai(_prompt, _config), do: {:error, "llm_api_key is required"}

  defp request(url, headers, payload, decode_fun) do
    base_headers = [
      {~c"user-agent", ~c"mom"},
      {~c"content-type", ~c"application/json"}
    ]

    body = Jason.encode!(payload)
    url_char = String.to_charlist(url)

    :inets.start()
    :ssl.start()

    do_request(url_char, base_headers ++ headers, body, decode_fun, 0)
  end

  defp do_request(url, headers, body, decode_fun, attempt) when attempt < 3 do
    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, status, _}, _headers, resp}} when status in 200..299 ->
        decode_fun.(resp)

      {:ok, {{_, status, _}, _headers, _resp}} when status in 429..599 ->
        backoff(attempt)
        do_request(url, headers, body, decode_fun, attempt + 1)

      {:ok, {{_, status, _}, _headers, resp}} ->
        {:error, %{type: :http_error, status: status, body: resp}}

      {:error, _reason} ->
        backoff(attempt)
        do_request(url, headers, body, decode_fun, attempt + 1)
    end
  end

  defp do_request(_url, _headers, _body, _decode_fun, attempt) do
    {:error, %{type: :retry_exhausted, attempts: attempt}}
  end

  defp backoff(attempt) do
    delay = trunc(:math.pow(2, attempt) * 250 + :rand.uniform(100))
    Process.sleep(delay)
  end
end
