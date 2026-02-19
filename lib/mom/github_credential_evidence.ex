defmodule Mom.GitHubCredentialEvidence do
  @moduledoc false

  alias Mom.{Audit, Security}

  @github_api "https://api.github.com"

  @spec verify(keyword()) :: {:ok, map()} | {:error, term()}
  def verify(opts) do
    required_scopes = Keyword.get(opts, :required_scopes, ["contents", "pull_requests", "issues"])
    token = Keyword.fetch!(opts, :github_token)
    repo = Keyword.get(opts, :github_repo)
    actor_id = Keyword.get(opts, :actor_id, "mom")
    allowed_egress_hosts = Keyword.get(opts, :allowed_egress_hosts, [])
    signing_key = Keyword.fetch!(opts, :startup_attestation_signing_key)

    with {:ok, pat_scopes, pat_error} <- fetch_pat_scopes(token, allowed_egress_hosts),
         {:ok, installation_permissions, installation_error} <-
           fetch_installation_permissions(repo, token, allowed_egress_hosts) do
      verified_scopes = verified_scopes(required_scopes, pat_scopes, installation_permissions)
      missing_scopes = required_scopes -- verified_scopes

      attestation_payload = %{
        actor_id: actor_id,
        repo: repo,
        required_scopes: required_scopes,
        pat_scopes: pat_scopes,
        installation_permissions: installation_permissions,
        verified_scopes: verified_scopes,
        missing_scopes: missing_scopes,
        pat_error: normalize_error(pat_error),
        installation_error: normalize_error(installation_error),
        attested_at_unix: DateTime.utc_now() |> DateTime.to_unix()
      }

      attestation_signature = sign_attestation(attestation_payload, signing_key)

      metadata =
        Map.merge(attestation_payload, %{
          attestation_signature: attestation_signature,
          attestation_key_id: signing_key_id(signing_key)
        })

      if missing_scopes == [] do
        :ok = Audit.emit(:github_credential_permission_attested, metadata)
        {:ok, metadata}
      else
        :ok = Audit.emit(:github_credential_permission_blocked, metadata)
        {:error, {:missing_permissions, missing_scopes}}
      end
    end
  end

  defp fetch_pat_scopes(token, allowed_egress_hosts) do
    case request(:get, "/rate_limit", token, nil, allowed_egress_hosts) do
      {:ok, _status, headers, _body} ->
        {:ok, parse_oauth_scopes_header(headers), nil}

      {:error, reason} ->
        {:ok, [], reason}
    end
  end

  defp fetch_installation_permissions(nil, _token, _allowed_egress_hosts),
    do: {:ok, %{}, :github_repo_missing}

  defp fetch_installation_permissions(repo, token, allowed_egress_hosts) do
    case request(:get, "/repos/#{repo}/installation", token, nil, allowed_egress_hosts) do
      {:ok, _status, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"permissions" => permissions}} when is_map(permissions) ->
            {:ok, permissions, nil}

          {:ok, _other} ->
            {:ok, %{}, :permissions_missing}

          {:error, reason} ->
            {:ok, %{}, {:invalid_json, reason}}
        end

      {:error, reason} ->
        {:ok, %{}, reason}
    end
  end

  defp request(method, path, token, payload, allowed_egress_hosts) do
    url = @github_api <> path

    if Security.egress_allowed?(url, allowed_egress_hosts) do
      headers = [
        {~c"authorization", ~c"Bearer " ++ to_charlist(token)},
        {~c"user-agent", ~c"mom"},
        {~c"accept", ~c"application/vnd.github+json"}
      ]

      request =
        if is_nil(payload) do
          {String.to_charlist(url), headers}
        else
          {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(payload)}
        end

      case http_client().request(method, request, [], []) do
        {:ok, {{_, status, _}, resp_headers, resp_body}} when status in 200..299 ->
          {:ok, status, resp_headers, to_string(resp_body)}

        {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
          {:error, {:http_error, status, to_string(resp_body)}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:egress_blocked, Security.url_host(url)}}
    end
  end

  defp parse_oauth_scopes_header(headers) do
    headers
    |> Enum.find_value([], fn {key, value} ->
      if String.downcase(to_string(key)) == "x-oauth-scopes" do
        value
        |> to_string()
        |> String.split(",", trim: true)
        |> Enum.map(&normalize_scope/1)
        |> Enum.reject(&(&1 == ""))
      else
        nil
      end
    end)
    |> Enum.uniq()
  end

  defp verified_scopes(required_scopes, pat_scopes, installation_permissions) do
    required_scopes
    |> Enum.filter(fn scope ->
      pat_scope_satisfies?(scope, pat_scopes) or
        installation_permission_satisfies?(scope, installation_permissions)
    end)
    |> Enum.uniq()
  end

  defp pat_scope_satisfies?(required_scope, pat_scopes) do
    normalized = MapSet.new(Enum.map(pat_scopes, &normalize_scope/1))
    MapSet.member?(normalized, "repo") or MapSet.member?(normalized, required_scope)
  end

  defp installation_permission_satisfies?(required_scope, installation_permissions) do
    case Map.get(installation_permissions, required_scope) do
      "write" -> true
      :write -> true
      true -> true
      _other -> false
    end
  end

  defp normalize_scope(scope) when is_binary(scope) do
    scope
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "_")
  end

  defp normalize_scope(scope), do: scope |> to_string() |> normalize_scope()

  defp sign_attestation(payload, signing_key) do
    encoded_payload = :erlang.term_to_binary(payload)

    :crypto.mac(:hmac, :sha256, signing_key, encoded_payload)
    |> Base.encode16(case: :lower)
  end

  defp signing_key_id(signing_key) do
    fingerprint =
      :crypto.hash(:sha256, signing_key)
      |> Base.encode16(case: :lower)

    "sha256:" <> String.slice(fingerprint, 0, 12)
  end

  defp normalize_error(nil), do: nil
  defp normalize_error(reason), do: inspect(reason)

  defp http_client do
    Application.get_env(:mom, :github_http_client, Mom.GitHub.HttpClient)
  end
end
