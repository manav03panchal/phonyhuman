# Multi-stage Dockerfile for Symphony (phonyhuman) orchestrator.
#
# Build:  docker build -t phonyhuman .
# Run:    docker run --rm -p 4000:4000 --env-file .env \
#           -v ./WORKFLOW.md:/etc/symphony/WORKFLOW.md:ro \
#           phonyhuman

# ---------------------------------------------------------------------------
# Stage 1 – build the escript binary
# ---------------------------------------------------------------------------
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4
ARG DEBIAN_VERSION=bookworm-20260223-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Hex + Rebar (build-only tooling)
RUN mix local.hex --force && mix local.rebar --force

# Dependency layer – cached until mix.exs / mix.lock change
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile

# Application source
COPY config config
COPY lib lib
COPY priv priv

# Build the escript
RUN MIX_ENV=prod mix escript.build

# ---------------------------------------------------------------------------
# Stage 2 – minimal runtime image
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION} AS runtime

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 libgcc-s1 libncurses6 libtinfo6 libssl3 \
      ca-certificates curl git openssh-client && \
    rm -rf /var/lib/apt/lists/*

# Copy the Erlang runtime from the build stage (escript needs the BEAM VM)
COPY --from=build /usr/local/lib/erlang /usr/local/lib/erlang
RUN ln -s /usr/local/lib/erlang/bin/erl      /usr/local/bin/erl      && \
    ln -s /usr/local/lib/erlang/bin/escript   /usr/local/bin/escript   && \
    ln -s /usr/local/lib/erlang/bin/erlc      /usr/local/bin/erlc

# Create non-root user
RUN groupadd -r symphony && \
    useradd -r -g symphony -m -d /home/symphony -s /bin/bash symphony

# Copy the escript binary
COPY --from=build /app/bin/symphony /usr/local/bin/symphony

# Prepare persistent directories
RUN mkdir -p /var/symphony/workspaces /var/log/symphony /etc/symphony && \
    chown -R symphony:symphony /var/symphony /var/log/symphony /etc/symphony

# SSH: known_hosts mount target + agent-forwarding socket directory
RUN mkdir -p /home/symphony/.ssh /run/ssh-agent && \
    chown symphony:symphony /home/symphony/.ssh /run/ssh-agent && \
    chmod 700 /home/symphony/.ssh

USER symphony
WORKDIR /home/symphony

EXPOSE 4000

# Health check – lightweight /health endpoint (HUM-41).
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -sf http://localhost:4000/health > /dev/null || exit 1

# The escript requires the acknowledgement flag. Configure the server to
# bind 0.0.0.0 so it is reachable from outside the container.
#
# WORKFLOW.md must be mounted or baked into /etc/symphony/WORKFLOW.md and
# should set:   server: { host: "0.0.0.0", port: 4000 }
#
# Alternatively, --port overrides the WORKFLOW.md server.port value.
ENTRYPOINT ["symphony"]
CMD [ \
  "--i-understand-that-this-will-be-running-without-the-usual-guardrails", \
  "--port", "4000", \
  "--logs-root", "/var/log/symphony", \
  "/etc/symphony/WORKFLOW.md" \
]
