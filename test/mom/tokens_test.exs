defmodule Mom.TokensTest do
  use ExUnit.Case, async: false

  alias Mom.Tokens

  setup do
    dir = Path.join(System.tmp_dir!(), "mom-tokens-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    start_supervised!({Tokens, data_dir: dir})
    {:ok, dir: dir}
  end

  test "new returns the token once and stores only its hash", %{dir: dir} do
    assert {:ok, "mom_" <> _ = token} = Tokens.new("claude-loop")
    body = File.read!(Path.join(dir, "tokens.json"))
    refute body =~ token
    assert body =~ Tokens.hash(token)
    assert [%{"name" => "claude-loop", "hash" => _, "created_at" => _}] = Jason.decode!(body)
    assert File.stat!(Path.join(dir, "tokens.json")).access in [:read_write, :read]
    assert [] = Path.wildcard(Path.join(dir, "*.tmp-*"))

    assert {:ok, "claude-loop"} = Tokens.verify(token)
    assert :error = Tokens.verify(token <> "x")
    assert :error = Tokens.verify("")
    assert :error = Tokens.verify(nil)
    assert [%{name: "claude-loop", created_at: _}] = Tokens.list()
  end

  test "names are unique and checked" do
    assert {:ok, _} = Tokens.new("a")
    assert {:error, :exists} = Tokens.new("a")
    assert {:error, :invalid_name} = Tokens.new("has space")
    assert {:error, :invalid_name} = Tokens.new(:atom)
  end

  test "revoke removes the token; tokens survive a restart", %{dir: dir} do
    {:ok, keep} = Tokens.new("keep")
    {:ok, drop} = Tokens.new("drop")
    assert :ok = Tokens.revoke("drop")
    assert {:error, :not_found} = Tokens.revoke("drop")
    assert :error = Tokens.verify(drop)

    stop_supervised!(Tokens)
    start_supervised!({Tokens, data_dir: dir})
    assert {:ok, "keep"} = Tokens.verify(keep)
    assert :error = Tokens.verify(drop)
    assert [%{name: "keep"}] = Tokens.list()
  end

  test "failed attempts are limited per address and per minute" do
    now = 1_800_000_000_000 - rem(1_800_000_000_000, 60_000)
    refute Tokens.blocked?("10.0.0.1", now)

    for _ <- 1..Tokens.failure_limit(), do: Tokens.record_failure("10.0.0.1", now)
    assert Tokens.blocked?("10.0.0.1", now + 59_999)
    refute Tokens.blocked?("10.0.0.2", now)

    # next minute: free again
    refute Tokens.blocked?("10.0.0.1", now + 60_000)
  end
end
