defmodule Mom.RateLimiterTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Mom.RateLimiter

  setup do
    Mom.TestHelper.reset_rate_limiter()
    :ok
  end

  test "enforces limit within window" do
    assert RateLimiter.allow?(:issue, 1, 10)
    refute RateLimiter.allow?(:issue, 1, 10)
    Process.sleep(15)
    assert RateLimiter.allow?(:issue, 1, 10)
  end

  test "dedupes issue signature within window" do
    assert RateLimiter.allow_issue_signature?("abc", 100)
    refute RateLimiter.allow_issue_signature?("abc", 100)
    Process.sleep(120)
    assert RateLimiter.allow_issue_signature?("abc", 100)
  end

  property "enforces limits for any small N" do
    check all n <- StreamData.integer(1..5) do
      Mom.TestHelper.reset_rate_limiter()
      assert Enum.all?(1..n, fn _ -> RateLimiter.allow?(:llm, n, 1_000_000) end)
      refute RateLimiter.allow?(:llm, n, 1_000_000)
    end
  end
end
