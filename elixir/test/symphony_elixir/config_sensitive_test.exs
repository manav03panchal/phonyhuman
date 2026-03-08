defmodule SymphonyElixir.ConfigSensitiveTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config

  describe "sensitive_fields/0" do
    test "returns a list of sensitive field atoms" do
      fields = Config.sensitive_fields()
      assert is_list(fields)
      assert :api_key in fields
      assert :linear_api_token in fields
    end
  end

  describe "sensitive?/1" do
    test "returns true for sensitive fields" do
      assert Config.sensitive?(:api_key)
      assert Config.sensitive?(:linear_api_token)
    end

    test "returns false for non-sensitive fields" do
      refute Config.sensitive?(:kind)
      refute Config.sensitive?(:endpoint)
      refute Config.sensitive?(:project_slug)
    end
  end
end
