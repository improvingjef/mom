Mix.Task.run("app.start")

record_path =
  Path.join(System.tmp_dir!(), "mom-harness-acceptance-#{System.unique_integer([:positive])}.json")

File.rm(record_path)

fake_runner = fn
  "gh", ["repo", "view", "acme/harness", "--json", "nameWithOwner,isPrivate,url,visibility"] ->
    {:ok,
     ~s({"nameWithOwner":"acme/harness","isPrivate":true,"url":"https://github.com/acme/harness","visibility":"PRIVATE"})}
end

{:ok, record} =
  Mom.HarnessRepo.confirm_and_record("acme/harness", record_path,
    cmd_runner: fake_runner,
    recorded_at: "2026-02-19T00:00:00Z"
  )

{:ok, loaded} = Mom.HarnessRepo.load_record(record_path)

IO.puts(
  "RESULT_JSON:" <>
    Jason.encode!(%{
      name_with_owner: record.name_with_owner,
      is_private: record.is_private,
      visibility: record.visibility,
      loaded_matches: loaded.name_with_owner == "acme/harness"
    })
)
