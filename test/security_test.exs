defmodule Mom.SecurityTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Mom.Security

  test "sanitizes nested structures" do
    input = %{
      "Token" => "abc",
      password: "secret",
      nested: [%{secret: "xyz"}],
      tuple: {:ok, %{api_key: "k"}}
    }

    result = Security.sanitize(input, ["password", "token", "secret", "api_key"])

    assert result.password == "[REDACTED]"
    assert result["Token"] == "[REDACTED]"
    assert result.nested == [%{secret: "[REDACTED]"}]
    assert result.tuple == {:ok, %{api_key: "[REDACTED]"}}
  end

  property "redacts password key in any map" do
    check all value <- term() do
      input = %{"password" => value, "ok" => 1}
      result = Security.sanitize(input, ["password"])
      assert result["password"] == "[REDACTED]"
      assert result["ok"] == 1
    end
  end

  property "redacts token key with mixed casing" do
    check all value <- term() do
      input = %{"ToKeN" => value, "ok" => 1}
      result = Security.sanitize(input, ["token"])
      assert result["ToKeN"] == "[REDACTED]"
      assert result["ok"] == 1
    end
  end

  test "signature is deterministic" do
    value = %{a: 1, b: [2, 3]}
    assert Security.signature(value) == Security.signature(value)
  end
end
