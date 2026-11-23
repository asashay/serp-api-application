FROM ruby:3.4.13-slim-bookworm@sha256:5a5585d0c13f42ed8503d56d4160dc2c19689cefc1a1acaff1ff91e82eef3577 AS base

WORKDIR /app
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test

FROM base AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential && \
    rm -rf /var/lib/apt/lists/*
COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache
COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

FROM base
RUN groupadd --gid 1000 rails && useradd --uid 1000 --gid rails --home-dir /app rails
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=rails:rails /app /app
USER rails
EXPOSE 3000
ENTRYPOINT ["bin/docker-entrypoint"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
