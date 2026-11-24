FROM ruby:3.4.13-slim-bookworm@sha256:5a5585d0c13f42ed8503d56d4160dc2c19689cefc1a1acaff1ff91e82eef3577 AS base

WORKDIR /app
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test

FROM base AS gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential && \
    rm -rf /var/lib/apt/lists/*
COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache

FROM gems AS build
COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

FROM base
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates python3-venv supervisor \
      libasound2 libdbus-glib-1-2 libgbm1 libgtk-3-0 libnss3 libx11-xcb1 libxt6 fonts-liberation && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd --gid 1000 rails && useradd --uid 1000 --gid rails --home-dir /app rails
ENV XDG_CACHE_HOME=/var/cache/renderer
COPY renderer/requirements.txt /tmp/renderer-requirements.txt
RUN python3 -m venv /opt/renderer && \
    /opt/renderer/bin/pip install --no-cache-dir -r /tmp/renderer-requirements.txt && \
    install -d -o rails -g rails /var/cache/renderer && \
    /opt/renderer/bin/invisible-playwright fetch && \
    chown -R rails:rails /var/cache/renderer
RUN usermod --home /home/rails rails && install -d -o rails -g rails /home/rails
COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=rails:rails /app /app
USER rails
EXPOSE 3000
ENTRYPOINT ["bin/docker-entrypoint"]
CMD ["supervisord", "-c", "renderer/supervisord.conf"]
