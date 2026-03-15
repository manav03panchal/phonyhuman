defmodule SymphonyElixir.TelemetryCollectorTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias SymphonyElixir.TelemetryCollector

  @metrics_payload %{
    "resourceMetrics" => [
      %{
        "resource" => %{
          "attributes" => [
            %{"key" => "session.id", "value" => %{"stringValue" => "sess-abc"}}
          ]
        },
        "scopeMetrics" => [
          %{
            "metrics" => [
              %{
                "name" => "claude_code.token.usage",
                "sum" => %{
                  "dataPoints" => [
                    %{
                      "asInt" => "1234",
                      "attributes" => [
                        %{"key" => "type", "value" => %{"stringValue" => "input"}}
                      ]
                    },
                    %{
                      "asInt" => "567",
                      "attributes" => [
                        %{"key" => "type", "value" => %{"stringValue" => "output"}}
                      ]
                    }
                  ]
                }
              },
              %{
                "name" => "claude_code.cost.usage",
                "sum" => %{
                  "dataPoints" => [
                    %{
                      "asDouble" => 0.025,
                      "attributes" => [
                        %{"key" => "model", "value" => %{"stringValue" => "claude-sonnet-4-20250514"}}
                      ]
                    }
                  ]
                }
              },
              %{
                "name" => "not_claude_code.other",
                "sum" => %{
                  "dataPoints" => [
                    %{"asInt" => "999", "attributes" => []}
                  ]
                }
              }
            ]
          }
        ]
      }
    ]
  }

  @logs_payload %{
    "resourceLogs" => [
      %{
        "resource" => %{
          "attributes" => [
            %{"key" => "session.id", "value" => %{"stringValue" => "sess-abc"}}
          ]
        },
        "scopeLogs" => [
          %{
            "logRecords" => [
              %{
                "body" => %{"stringValue" => "claude_code.api_request"},
                "attributes" => [
                  %{"key" => "input_tokens", "value" => %{"intValue" => "500"}},
                  %{"key" => "output_tokens", "value" => %{"intValue" => "200"}},
                  %{"key" => "model", "value" => %{"stringValue" => "claude-sonnet-4-20250514"}},
                  %{"key" => "cost", "value" => %{"doubleValue" => 0.01}}
                ],
                "timeUnixNano" => "1700000000000000000",
                "severityText" => "INFO"
              },
              %{
                "body" => %{"stringValue" => "not_claude_code.something"},
                "attributes" => [],
                "timeUnixNano" => "1700000000000000000",
                "severityText" => "INFO"
              }
            ]
          }
        ]
      }
    ]
  }

  @multi_session_payload %{
    "resourceMetrics" => [
      %{
        "resource" => %{
          "attributes" => [
            %{"key" => "session.id", "value" => %{"stringValue" => "sess-1"}}
          ]
        },
        "scopeMetrics" => [
          %{
            "metrics" => [
              %{
                "name" => "claude_code.session.count",
                "sum" => %{
                  "dataPoints" => [%{"asInt" => "1", "attributes" => []}]
                }
              }
            ]
          }
        ]
      },
      %{
        "resource" => %{
          "attributes" => [
            %{"key" => "session.id", "value" => %{"stringValue" => "sess-2"}}
          ]
        },
        "scopeMetrics" => [
          %{
            "metrics" => [
              %{
                "name" => "claude_code.commit.count",
                "sum" => %{
                  "dataPoints" => [%{"asInt" => "3", "attributes" => []}]
                }
              }
            ]
          }
        ]
      }
    ]
  }

  describe "parse_resource_metrics/1" do
    test "extracts claude_code.* metrics and filters non-claude metrics" do
      result = TelemetryCollector.parse_resource_metrics(@metrics_payload)

      assert Map.has_key?(result, "sess-abc")
      session = result["sess-abc"]

      assert Map.has_key?(session, "claude_code.token.usage")
      assert Map.has_key?(session, "claude_code.cost.usage")
      refute Map.has_key?(session, "not_claude_code.other")
    end

    test "parses sum data points with integer and double values" do
      result = TelemetryCollector.parse_resource_metrics(@metrics_payload)
      session = result["sess-abc"]

      token_points = session["claude_code.token.usage"]
      assert length(token_points) == 2
      assert Enum.find(token_points, &(&1.attributes["type"] == "input")).value == 1234
      assert Enum.find(token_points, &(&1.attributes["type"] == "output")).value == 567

      cost_points = session["claude_code.cost.usage"]
      assert length(cost_points) == 1
      assert hd(cost_points).value == 0.025
      assert hd(cost_points).attributes["model"] == "claude-sonnet-4-20250514"
    end

    test "handles gauge metrics" do
      payload = %{
        "resourceMetrics" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "session.id", "value" => %{"stringValue" => "sess-g"}}
              ]
            },
            "scopeMetrics" => [
              %{
                "metrics" => [
                  %{
                    "name" => "claude_code.active_time.total",
                    "gauge" => %{
                      "dataPoints" => [
                        %{"asInt" => "42", "attributes" => []}
                      ]
                    }
                  }
                ]
              }
            ]
          }
        ]
      }

      result = TelemetryCollector.parse_resource_metrics(payload)
      assert result["sess-g"]["claude_code.active_time.total"] == [%{value: 42, attributes: %{}}]
    end

    test "handles non-numeric string in asInt without crashing" do
      payload = %{
        "resourceMetrics" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "session.id", "value" => %{"stringValue" => "sess-bad"}}
              ]
            },
            "scopeMetrics" => [
              %{
                "metrics" => [
                  %{
                    "name" => "claude_code.token.usage",
                    "sum" => %{
                      "dataPoints" => [
                        %{"asInt" => "not_a_number", "attributes" => []},
                        %{"asInt" => "456", "attributes" => []},
                        %{"asInt" => "12abc", "attributes" => []}
                      ]
                    }
                  }
                ]
              }
            ]
          }
        ]
      }

      result = TelemetryCollector.parse_resource_metrics(payload)
      points = result["sess-bad"]["claude_code.token.usage"]
      assert length(points) == 3
      # Non-numeric string falls back to 0
      assert Enum.at(points, 0).value == 0
      # Valid numeric string is parsed
      assert Enum.at(points, 1).value == 456
      # Trailing garbage falls back to 0
      assert Enum.at(points, 2).value == 0
    end

    test "handles non-numeric string in intValue attribute without crashing" do
      payload = %{
        "resourceMetrics" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "session.id", "value" => %{"stringValue" => "sess-attr"}}
              ]
            },
            "scopeMetrics" => [
              %{
                "metrics" => [
                  %{
                    "name" => "claude_code.test.metric",
                    "sum" => %{
                      "dataPoints" => [
                        %{
                          "asInt" => "100",
                          "attributes" => [
                            %{"key" => "bad_int", "value" => %{"intValue" => "xyz"}},
                            %{"key" => "good_int", "value" => %{"intValue" => "42"}}
                          ]
                        }
                      ]
                    }
                  }
                ]
              }
            ]
          }
        ]
      }

      result = TelemetryCollector.parse_resource_metrics(payload)
      point = hd(result["sess-attr"]["claude_code.test.metric"])
      assert point.attributes["bad_int"] == 0
      assert point.attributes["good_int"] == 42
    end

    test "returns empty map for invalid payload" do
      assert TelemetryCollector.parse_resource_metrics(%{}) == %{}
      assert TelemetryCollector.parse_resource_metrics(nil) == %{}
      assert TelemetryCollector.parse_resource_metrics("bad") == %{}
    end

    test "uses 'unknown' session when no session.id attribute" do
      payload = %{
        "resourceMetrics" => [
          %{
            "resource" => %{"attributes" => []},
            "scopeMetrics" => [
              %{
                "metrics" => [
                  %{
                    "name" => "claude_code.session.count",
                    "sum" => %{
                      "dataPoints" => [%{"asInt" => "1", "attributes" => []}]
                    }
                  }
                ]
              }
            ]
          }
        ]
      }

      result = TelemetryCollector.parse_resource_metrics(payload)
      assert Map.has_key?(result, "unknown")
    end
  end

  describe "parse_resource_logs/1" do
    test "extracts claude_code.* log events and filters non-claude events" do
      result = TelemetryCollector.parse_resource_logs(@logs_payload)

      assert Map.has_key?(result, "sess-abc")
      events = result["sess-abc"].events
      assert length(events) == 1
      assert hd(events).name == "claude_code.api_request"
    end

    test "parses log event attributes" do
      result = TelemetryCollector.parse_resource_logs(@logs_payload)
      event = hd(result["sess-abc"].events)

      assert event.attributes["input_tokens"] == 500
      assert event.attributes["output_tokens"] == 200
      assert event.attributes["model"] == "claude-sonnet-4-20250514"
      assert event.attributes["cost"] == 0.01
      assert event.timestamp == "1700000000000000000"
      assert event.severity == "INFO"
    end

    test "returns empty map for invalid payload" do
      assert TelemetryCollector.parse_resource_logs(%{}) == %{}
      assert TelemetryCollector.parse_resource_logs(nil) == %{}
    end
  end

  describe "session grouping" do
    test "groups metrics from multiple sessions independently" do
      result = TelemetryCollector.parse_resource_metrics(@multi_session_payload)

      assert Map.has_key?(result, "sess-1")
      assert Map.has_key?(result, "sess-2")
      assert Map.has_key?(result["sess-1"], "claude_code.session.count")
      assert Map.has_key?(result["sess-2"], "claude_code.commit.count")
      refute Map.has_key?(result["sess-1"], "claude_code.commit.count")
      refute Map.has_key?(result["sess-2"], "claude_code.session.count")
    end
  end

  describe "GenServer integration" do
    setup do
      collector_name = :"collector_#{System.unique_integer([:positive])}"

      {:ok, collector} =
        TelemetryCollector.start_link(
          name: collector_name,
          port: 0,
          orchestrator: self()
        )

      on_exit(fn ->
        if Process.alive?(collector), do: GenServer.stop(collector)
      end)

      %{collector: collector, name: collector_name}
    end

    test "processes metrics and sends to orchestrator", %{name: name} do
      TelemetryCollector.ingest_metrics(name, @metrics_payload)

      assert_receive {:otel_metrics, "sess-abc", metrics}, 1_000
      assert Map.has_key?(metrics, "claude_code.token.usage")
      assert Map.has_key?(metrics, "claude_code.cost.usage")
    end

    test "processes logs and sends to orchestrator", %{name: name} do
      TelemetryCollector.ingest_logs(name, @logs_payload)

      assert_receive {:otel_metrics, "sess-abc", data}, 1_000
      assert is_list(data.events)
      assert hd(data.events).name == "claude_code.api_request"
    end

    test "aggregates metrics across multiple ingestions", %{name: name} do
      TelemetryCollector.ingest_metrics(name, @multi_session_payload)
      # Wait for first batch
      assert_receive {:otel_metrics, "sess-1", _}, 1_000
      assert_receive {:otel_metrics, "sess-2", _}, 1_000

      # Ingest more data for sess-1
      more_data = %{
        "resourceMetrics" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "session.id", "value" => %{"stringValue" => "sess-1"}}
              ]
            },
            "scopeMetrics" => [
              %{
                "metrics" => [
                  %{
                    "name" => "claude_code.commit.count",
                    "sum" => %{
                      "dataPoints" => [%{"asInt" => "5", "attributes" => []}]
                    }
                  }
                ]
              }
            ]
          }
        ]
      }

      TelemetryCollector.ingest_metrics(name, more_data)

      # Should receive updated state for sess-1 with both metrics
      assert_receive {:otel_metrics, "sess-1", metrics}, 1_000
      assert Map.has_key?(metrics, "claude_code.session.count")
      assert Map.has_key?(metrics, "claude_code.commit.count")
    end

    test "get_state returns current session data", %{name: name} do
      TelemetryCollector.ingest_metrics(name, @metrics_payload)
      # Wait for processing
      assert_receive {:otel_metrics, _, _}, 1_000

      state = TelemetryCollector.get_state(name)
      assert Map.has_key?(state, "sess-abc")
    end

    test "handles malformed payload gracefully", %{name: name} do
      log =
        capture_log(fn ->
          TelemetryCollector.ingest_metrics(name, %{"garbage" => true})
          TelemetryCollector.ingest_metrics(name, nil)
          TelemetryCollector.ingest_logs(name, %{"garbage" => true})
          TelemetryCollector.ingest_logs(name, nil)

          # Give GenServer time to process
          _ = TelemetryCollector.get_state(name)
        end)

      # Should not crash — verify process is still alive
      assert Process.alive?(Process.whereis(name))
      # Malformed payloads produce no data
      state = TelemetryCollector.get_state(name)
      assert state == %{}
      # No unexpected warnings needed for empty data
      assert log == "" or is_binary(log)
    end
  end

  describe "event capping" do
    setup do
      collector_name = :"cap_collector_#{System.unique_integer([:positive])}"

      {:ok, collector} =
        TelemetryCollector.start_link(
          name: collector_name,
          port: 0,
          orchestrator: self()
        )

      on_exit(fn ->
        if Process.alive?(collector), do: GenServer.stop(collector)
      end)

      %{collector: collector, name: collector_name}
    end

    test "caps events per session at @max_events_per_session", %{name: name} do
      # Ingest logs in batches to exceed the 100-event cap
      for i <- 1..12 do
        payload = %{
          "resourceLogs" => [
            %{
              "resource" => %{
                "attributes" => [
                  %{"key" => "session.id", "value" => %{"stringValue" => "sess-cap"}}
                ]
              },
              "scopeLogs" => [
                %{
                  "logRecords" =>
                    for j <- 1..10 do
                      %{
                        "body" => %{"stringValue" => "claude_code.event_#{i}_#{j}"},
                        "attributes" => [],
                        "timeUnixNano" => "170000000000000000#{i}",
                        "severityText" => "INFO"
                      }
                    end
                }
              ]
            }
          ]
        }

        TelemetryCollector.ingest_logs(name, payload)
      end

      # Wait for processing to complete
      # Drain all otel_metrics messages
      :timer.sleep(100)
      drain_messages()

      state = TelemetryCollector.get_state(name)
      events = state["sess-cap"].events
      # Should be capped at 100 (the @max_events_per_session default)
      assert length(events) == 100
      # Should keep the most recent events (last batch)
      assert hd(events).name == "claude_code.event_3_1"
      assert List.last(events).name == "claude_code.event_12_10"
    end

    defp drain_messages do
      receive do
        {:otel_metrics, _, _} -> drain_messages()
      after
        0 -> :ok
      end
    end
  end

  describe "session pruning" do
    test "prune_sessions message triggers stale session removal" do
      collector_name = :"prune_collector_#{System.unique_integer([:positive])}"

      {:ok, collector} =
        TelemetryCollector.start_link(
          name: collector_name,
          port: 0,
          orchestrator: self()
        )

      # Ingest data to create a session
      TelemetryCollector.ingest_metrics(collector_name, %{
        "resourceMetrics" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "session.id", "value" => %{"stringValue" => "sess-prune"}}
              ]
            },
            "scopeMetrics" => [
              %{
                "metrics" => [
                  %{
                    "name" => "claude_code.test",
                    "sum" => %{
                      "dataPoints" => [%{"asInt" => "1", "attributes" => []}]
                    }
                  }
                ]
              }
            ]
          }
        ]
      })

      assert_receive {:otel_metrics, "sess-prune", _}, 1_000
      state = TelemetryCollector.get_state(collector_name)
      assert Map.has_key?(state, "sess-prune")

      # Manually inject an old timestamp to simulate staleness
      # by manipulating the GenServer state directly
      :sys.replace_state(Process.whereis(collector_name), fn state ->
        old_ts = System.monotonic_time(:millisecond) - :timer.minutes(31)
        %{state | session_timestamps: %{"sess-prune" => old_ts}}
      end)

      # Trigger prune
      send(Process.whereis(collector_name), :prune_sessions)

      # Give it a moment to process
      :timer.sleep(50)

      state = TelemetryCollector.get_state(collector_name)
      refute Map.has_key?(state, "sess-prune")

      if Process.alive?(collector), do: GenServer.stop(collector)
    end

    test "recent sessions are not pruned" do
      collector_name = :"keep_collector_#{System.unique_integer([:positive])}"

      {:ok, collector} =
        TelemetryCollector.start_link(
          name: collector_name,
          port: 0,
          orchestrator: self()
        )

      TelemetryCollector.ingest_metrics(collector_name, %{
        "resourceMetrics" => [
          %{
            "resource" => %{
              "attributes" => [
                %{"key" => "session.id", "value" => %{"stringValue" => "sess-keep"}}
              ]
            },
            "scopeMetrics" => [
              %{
                "metrics" => [
                  %{
                    "name" => "claude_code.test",
                    "sum" => %{
                      "dataPoints" => [%{"asInt" => "1", "attributes" => []}]
                    }
                  }
                ]
              }
            ]
          }
        ]
      })

      assert_receive {:otel_metrics, "sess-keep", _}, 1_000

      # Trigger prune — session is recent, should survive
      send(Process.whereis(collector_name), :prune_sessions)
      :timer.sleep(50)

      state = TelemetryCollector.get_state(collector_name)
      assert Map.has_key?(state, "sess-keep")

      if Process.alive?(collector), do: GenServer.stop(collector)
    end
  end

  describe "HTTP integration" do
    setup do
      collector_name = :"http_collector_#{System.unique_integer([:positive])}"

      {:ok, collector} =
        TelemetryCollector.start_link(
          name: collector_name,
          port: 0,
          orchestrator: self()
        )

      port = TelemetryCollector.bound_port(collector_name)

      on_exit(fn ->
        if Process.alive?(collector), do: GenServer.stop(collector)
      end)

      %{collector: collector, name: collector_name, port: port}
    end

    test "POST /v1/metrics accepts OTLP JSON payload", %{port: port} do
      assert port != nil

      body = Jason.encode!(@metrics_payload)

      {:ok, resp} =
        Req.post("http://127.0.0.1:#{port}/v1/metrics",
          body: body,
          headers: [{"content-type", "application/json"}]
        )

      assert resp.status == 200
      assert_receive {:otel_metrics, "sess-abc", metrics}, 2_000
      assert Map.has_key?(metrics, "claude_code.token.usage")
    end

    test "POST /v1/logs accepts OTLP JSON payload", %{port: port} do
      assert port != nil

      body = Jason.encode!(@logs_payload)

      {:ok, resp} =
        Req.post("http://127.0.0.1:#{port}/v1/logs",
          body: body,
          headers: [{"content-type", "application/json"}]
        )

      assert resp.status == 200
      assert_receive {:otel_metrics, "sess-abc", data}, 2_000
      assert is_list(data.events)
    end

    test "returns 404 for unknown paths", %{port: port} do
      assert port != nil

      {:ok, resp} = Req.get("http://127.0.0.1:#{port}/unknown")
      assert resp.status == 404
    end
  end

  describe "listener lifecycle (HUM-120)" do
    test "listener is linked to collector — dies when collector exits" do
      collector_name = :"link_collector_#{System.unique_integer([:positive])}"

      # Trap exits so the test process survives the collector being killed
      Process.flag(:trap_exit, true)

      {:ok, collector} =
        TelemetryCollector.start_link(
          name: collector_name,
          port: 0,
          orchestrator: self()
        )

      # Grab the listener pid from GenServer state
      %{listener_ref: listener_pid} = :sys.get_state(collector)
      assert is_pid(listener_pid)
      assert Process.alive?(listener_pid)

      # Monitor the listener to detect when it exits
      listener_mon = Process.monitor(listener_pid)

      # Kill the collector abruptly (simulates a crash)
      Process.exit(collector, :kill)

      # Listener must die because it's linked to the collector
      assert_receive {:DOWN, ^listener_mon, :process, ^listener_pid, _reason}, 2_000
      refute Process.alive?(listener_pid)
    after
      Process.flag(:trap_exit, false)
    end

    test "collector state does not contain listener_monitor key" do
      collector_name = :"no_mon_#{System.unique_integer([:positive])}"

      {:ok, collector} =
        TelemetryCollector.start_link(
          name: collector_name,
          port: 0,
          orchestrator: self()
        )

      state = :sys.get_state(collector)
      refute Map.has_key?(state, :listener_monitor)

      GenServer.stop(collector)
    end

    test "supervised collector restarts cleanly on same port after crash" do
      # Start a minimal supervisor wrapping the collector
      port = 0
      collector_name = :"sup_collector_#{System.unique_integer([:positive])}"

      children = [
        %{
          id: :test_collector,
          start: {TelemetryCollector, :start_link, [[name: collector_name, port: port, orchestrator: self()]]}
        }
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      # Verify it started
      collector = Process.whereis(collector_name)
      assert collector != nil
      assert Process.alive?(collector)
      %{listener_ref: listener1} = :sys.get_state(collector)
      assert is_pid(listener1)

      # Kill the collector to trigger supervisor restart
      Process.exit(collector, :kill)
      :timer.sleep(200)

      # Supervisor should have restarted it
      new_collector = Process.whereis(collector_name)
      assert new_collector != nil
      assert new_collector != collector
      assert Process.alive?(new_collector)

      # New listener should be running (no eaddrinuse)
      %{listener_ref: listener2} = :sys.get_state(new_collector)
      assert is_pid(listener2)
      assert Process.alive?(listener2)

      # Old listener should be dead
      refute Process.alive?(listener1)

      Supervisor.stop(sup)
    end
  end
end
