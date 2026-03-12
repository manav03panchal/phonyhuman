defmodule SymphonyElixir.Linear.ClientErrorRedactionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Linear.Client

  describe "graphql/3 error logging" do
    test "redacts Authorization header from error reason in logs" do
      headers_with_auth = [{"Authorization", "lin_api_secret_token"}, {"Content-Type", "application/json"}]

      error_with_headers =
        {:error, %{reason: :connection_refused, request_headers: headers_with_auth}}

      mock_request = fn _payload, _headers -> error_with_headers end

      log =
        capture_log(fn ->
          Client.graphql("query { viewer { id } }", %{}, request_fun: mock_request)
        end)

      refute log =~ "lin_api_secret_token"
      assert log =~ "[REDACTED]"
    end

    test "redacts Authorization header from non-200 response body in logs" do
      response_with_auth_echo = %{
        status: 401,
        body: ~s({"error": "Invalid token", "received_auth": "Authorization: lin_api_leaked_token"})
      }

      mock_request = fn _payload, _headers -> {:ok, response_with_auth_echo} end

      log =
        capture_log(fn ->
          Client.graphql("query { viewer { id } }", %{}, request_fun: mock_request)
        end)

      refute log =~ "lin_api_leaked_token"
      assert log =~ "[REDACTED]"
      assert log =~ "status=401"
    end

    test "preserves useful debugging context in error logs" do
      response = %{
        status: 500,
        body: ~s({"error": "Internal server error", "message": "rate limited"})
      }

      mock_request = fn _payload, _headers -> {:ok, response} end

      log =
        capture_log(fn ->
          Client.graphql("query { viewer { id } }", %{},
            request_fun: mock_request,
            operation_name: "TestOp"
          )
        end)

      assert log =~ "status=500"
      assert log =~ "operation=TestOp"
      assert log =~ "rate limited"
    end
  end
end
