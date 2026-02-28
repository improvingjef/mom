defmodule Mom.Governance.Gates.Protocols.ActorIdentityGate do
  @moduledoc false

  @enforce_keys [:actor_id, :allowed_actor_ids, :github_token_present]
  defstruct [:actor_id, :allowed_actor_ids, :github_token_present]

  @type t :: %__MODULE__{
          actor_id: String.t(),
          allowed_actor_ids: [String.t()],
          github_token_present: boolean()
        }

  defimpl Mom.Governance.Gates.Protocols.Gate do
    alias Mom.Governance.Gates.Result

    @impl true
    def gate(_input), do: :actor_identity

    @impl true
    def evaluate(%{
          actor_id: actor_id,
          allowed_actor_ids: allowed_actor_ids,
          github_token_present: github_token_present
        }) do
      cond do
        actor_id == "" ->
          Result.deny(:actor_identity, "actor_id must not be empty", %{reason_code: :empty_actor_id})

        github_token_present and allowed_actor_ids == [] ->
          Result.deny(
            :actor_identity,
            "allowed_actor_ids must be set when github_token is configured",
            %{reason_code: :allowed_actor_ids_required}
          )

        allowed_actor_ids != [] and actor_id not in allowed_actor_ids ->
          Result.deny(:actor_identity, "actor_id is not allowed", %{reason_code: :actor_not_allowed})

        github_token_present and not machine_actor_identity?(actor_id) ->
          Result.deny(:actor_identity, "actor_id must be a dedicated machine identity", %{
            reason_code: :machine_identity_required
          })

        true ->
          Result.allow(:actor_identity, %{actor_id: actor_id})
      end
    end

    defp machine_actor_identity?(actor_id) when is_binary(actor_id) do
      normalized = String.downcase(actor_id)

      String.ends_with?(normalized, "[bot]") or
        String.contains?(normalized, "-bot") or
        String.contains?(normalized, "_bot") or
        String.starts_with?(normalized, "app/")
    end
  end
end
