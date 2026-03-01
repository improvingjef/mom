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
    check all(value <- term()) do
      input = %{"password" => value, "ok" => 1}
      result = Security.sanitize(input, ["password"])
      assert result["password"] == "[REDACTED]"
      assert result["ok"] == 1
    end
  end

  property "redacts token key with mixed casing" do
    check all(value <- term()) do
      input = %{"ToKeN" => value, "ok" => 1}
      result = Security.sanitize(input, ["token"])
      assert result["ToKeN"] == "[REDACTED]"
      assert result["ok"] == 1
    end
  end

  test "sanitize handles OTP logger events with exception structs and stacktraces" do
    # Logger events from OTP contain structs (e.g. BadMapError) and charlist stacktraces.
    # The sanitizer must not crash on these shapes.
    logger_event = %{
      level: :error,
      msg: {:report, %{label: {:proc_lib, :crash}}},
      meta: %{
        crash_reason: {
          %BadMapError{term: nil},
          [{Enum, :map, 2, [file: ~c"lib/enum.ex", line: 1688]}]
        },
        pid: self(),
        gl: self()
      }
    }

    result = Security.sanitize(logger_event, ["password", "token"])
    assert is_map(result)
  end

  test "signature is deterministic" do
    value = %{a: 1, b: [2, 3]}
    assert Security.signature(value) == Security.signature(value)
  end

  test "egress_allowed? matches URL host against allowlist" do
    assert Security.egress_allowed?("https://api.github.com/repos/acme/mom", ["api.github.com"])

    refute Security.egress_allowed?("https://api.openai.com/v1/chat/completions", [
             "api.github.com"
           ])
  end
end
