defmodule SymphonyElixir.RuntimeConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  describe "secret_key_base!/1" do
    test "raises in prod when SECRET_KEY_BASE is not set" do
      System.delete_env("SECRET_KEY_BASE")

      assert_raise RuntimeError, ~r/SECRET_KEY_BASE is missing/, fn ->
        SymphonyElixir.RuntimeConfig.secret_key_base!(:prod)
      end
    end

    test "generates a random key in dev when SECRET_KEY_BASE is not set" do
      System.delete_env("SECRET_KEY_BASE")

      key = SymphonyElixir.RuntimeConfig.secret_key_base!(:dev)
      assert is_binary(key)
      assert byte_size(key) == 64
    end

    test "generates a random key in test when SECRET_KEY_BASE is not set" do
      System.delete_env("SECRET_KEY_BASE")

      key = SymphonyElixir.RuntimeConfig.secret_key_base!(:test)
      assert is_binary(key)
      assert byte_size(key) == 64
    end

    test "uses SECRET_KEY_BASE env var when set" do
      System.put_env("SECRET_KEY_BASE", "test-secret-key-base-value-for-testing")

      key = SymphonyElixir.RuntimeConfig.secret_key_base!(:prod)
      assert key == "test-secret-key-base-value-for-testing"
    after
      System.delete_env("SECRET_KEY_BASE")
    end
  end

  describe "parse_port/0" do
    test "defaults to 4000 when PORT is not set" do
      System.delete_env("PORT")
      assert SymphonyElixir.RuntimeConfig.parse_port() == 4000
    end

    test "parses valid PORT" do
      System.put_env("PORT", "8080")
      assert SymphonyElixir.RuntimeConfig.parse_port() == 8080
    after
      System.delete_env("PORT")
    end

    test "falls back to 4000 on non-integer PORT" do
      System.put_env("PORT", "abc")

      log =
        capture_log(fn ->
          assert SymphonyElixir.RuntimeConfig.parse_port() == 4000
        end)

      assert log =~ "PORT=abc is not a valid integer"
    after
      System.delete_env("PORT")
    end

    test "falls back to 4000 on PORT with trailing characters" do
      System.put_env("PORT", "80abc")

      log =
        capture_log(fn ->
          assert SymphonyElixir.RuntimeConfig.parse_port() == 4000
        end)

      assert log =~ "not a valid integer"
    after
      System.delete_env("PORT")
    end

    test "falls back to 4000 when PORT exceeds 65535" do
      System.put_env("PORT", "99999")

      log =
        capture_log(fn ->
          assert SymphonyElixir.RuntimeConfig.parse_port() == 4000
        end)

      assert log =~ "outside valid range"
    after
      System.delete_env("PORT")
    end

    test "falls back to 4000 when PORT is 0" do
      System.put_env("PORT", "0")

      log =
        capture_log(fn ->
          assert SymphonyElixir.RuntimeConfig.parse_port() == 4000
        end)

      assert log =~ "outside valid range"
    after
      System.delete_env("PORT")
    end

    test "falls back to 4000 when PORT is negative" do
      System.put_env("PORT", "-1")

      log =
        capture_log(fn ->
          assert SymphonyElixir.RuntimeConfig.parse_port() == 4000
        end)

      assert log =~ "outside valid range"
    after
      System.delete_env("PORT")
    end

    test "accepts port 1 (minimum)" do
      System.put_env("PORT", "1")
      assert SymphonyElixir.RuntimeConfig.parse_port() == 1
    after
      System.delete_env("PORT")
    end

    test "accepts port 65535 (maximum)" do
      System.put_env("PORT", "65535")
      assert SymphonyElixir.RuntimeConfig.parse_port() == 65_535
    after
      System.delete_env("PORT")
    end
  end

  describe "check_origin/0" do
    test "defaults to true when ALLOWED_ORIGINS is not set" do
      System.delete_env("ALLOWED_ORIGINS")

      assert SymphonyElixir.RuntimeConfig.check_origin() == true
    end

    test "parses comma-separated ALLOWED_ORIGINS" do
      System.put_env("ALLOWED_ORIGINS", "https://example.com,https://app.example.com")

      assert SymphonyElixir.RuntimeConfig.check_origin() == [
               "https://example.com",
               "https://app.example.com"
             ]
    after
      System.delete_env("ALLOWED_ORIGINS")
    end

    test "trims whitespace from ALLOWED_ORIGINS" do
      System.put_env("ALLOWED_ORIGINS", " https://example.com , https://app.example.com ")

      assert SymphonyElixir.RuntimeConfig.check_origin() == [
               "https://example.com",
               "https://app.example.com"
             ]
    after
      System.delete_env("ALLOWED_ORIGINS")
    end
  end
end
