defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:put_secure_browser_headers, %{
      "x-frame-options" => "DENY",
      "x-content-type-options" => "nosniff",
      "strict-transport-security" => "max-age=63072000"
    })

    plug(SymphonyElixirWeb.Plugs.RateLimiter)
  end

  pipeline :api_auth do
    plug(SymphonyElixirWeb.Plugs.BearerAuth)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:api)

    get("/health", HealthController, :index)

    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/events", EventsController, :events)
  end

  # Authenticated POST endpoints — require Bearer token when SYMPHONY_API_KEY is set
  scope "/", SymphonyElixirWeb do
    pipe_through([:api, :api_auth])

    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    post("/api/v1/fleet/pause", ObservabilityApiController, :pause)
    post("/api/v1/fleet/resume", ObservabilityApiController, :resume)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:api)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/events", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/fleet/pause", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/fleet/resume", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
