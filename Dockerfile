ARG RUBY_VERSION="2.7.1"
FROM ruby:${RUBY_VERSION}-alpine as Builder
ARG FOLDERS_TO_REMOVE="spec node_modules vendor/assets lib/assets app/assets/images app/assets/stylesheets app/assets/javascritp"
ARG BUNDLE_WITHOUT="development:test"
ARG RAILS_ENV=production
ARG NODE_ENV=production
ARG NODE_VERSION="12"
ARG RESET_CREDENTIALS
ARG RAILS_MASTER_KEY

ENV BUNDLE_WITHOUT ${BUNDLE_WITHOUT}
ENV RAILS_ENV ${RAILS_ENV}
ENV NODE_ENV ${NODE_ENV}
ENV RESET_CREDENTIALS ${RESET_CREDENTIALS}
ENV RAILS_MASTER_KEY ${RAILS_MASTER_KEY}

RUN apk add --update --no-cache \
    build-base \
    postgresql-dev \
    git \
    yarn \
    tzdata \
    gcompat \
    gcc

#build and install jemalloc (not part of official alpine release)
RUN wget -O - https://github.com/jemalloc/jemalloc/releases/download/5.2.1/jemalloc-5.2.1.tar.bz2 | tar -xj && \
    cd jemalloc-5.2.1 && \
    ./configure && \
    make && \
    make install

RUN if [ "$NODE_VERSION" = 8 ] ; then apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/v3.8/main/ nodejs=8.14.0-r0 npm ; else echo Not installing 8 ; fi
RUN if [ "$NODE_VERSION" = 10 ] ; then apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/v3.10/main/ nodejs=10.19.0-r0 npm ; else echo Not installing 10 ; fi
#RUN if [ "$NODE_VERSION" = 12 ] ; then apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/v3.12/main/ nodejs=12.16.3-r1 npm ; else echo Not installing 12 ; fi
RUN if [ "$NODE_VERSION" = 12 ] ; then apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/v3.11/main/ nodejs=12.15.0-r1 npm ; else echo Not installing 12 ; fi

WORKDIR /app

RUN gem install bundler

# Install gems
ADD Gemfile* /app/
RUN bundle config --global frozen 1 \
 && bundle install -j4 --retry 3 \
 # Remove unneeded files (cached *.gem, *.o, *.c)
 && rm -rf /usr/local/bundle/cache/*.gem \
 && find /usr/local/bundle/gems/ -name "*.c" -delete \
 && find /usr/local/bundle/gems/ -name "*.o" -delete

# Install yarn packages
#COPY package.json yarn.lock /app/
#RUN yarn install

# Add the Rails app
ADD . /app

# Precompile assets with dummy key
RUN SECRET_KEY_BASE='bin/rake secret' bundle exec rake assets:precompile

#create rails master key if it is not part of package
RUN if [ "$RESET_CREDENTIALS" = true ] ; then EDITOR="cat" rails credentials:edit ; else echo Using credentials ; fi

# Remove folders not needed in resulting image
RUN rm -rf $FOLDERS_TO_REMOVE

###############################
# Stage wkhtmltopdf and wkhtmltoimage
FROM surnet/alpine-wkhtmltopdf:3.10-0.12.5-full as wkhtmltopdf

###############################
# Stage Final
FROM ruby:${RUBY_VERSION}-alpine
LABEL maintainer="pasi.vuorio@nativesoft.fi"

ARG ADDITIONAL_PACKAGES
ARG EXECJS_RUNTIME=Disabled
ARG RAILS_ENV=production
ARG NODE_ENV=production
ARG NODE_VERSION="12"
ARG PORT="3000"

ENV RAILS_ENV ${RAILS_ENV}
ENV BUNDLE_DISABLE_EXEC_LOAD true

#use jemalloc better memory usage and performance
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2

# Add Alpine packages
RUN apk add --update --no-cache \
    postgresql-client \
    imagemagick \
    vips \
    $ADDITIONAL_PACKAGES \
    tzdata \
    file \
    curl \
    gcompat \
    # needed for wkhtmltopdf
    libcrypto1.1 libssl1.1 glib libxrender libxext libx11 \
    ttf-dejavu ttf-droid ttf-freefont ttf-liberation ttf-ubuntu-font-family

RUN if [ "$NODE_VERSION" = 8 ] ; then apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/v3.8/main/ nodejs=8.14.0-r0 npm ; else echo Not installing 8 ; fi
RUN if [ "$NODE_VERSION" = 10 ] ; then apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/v3.10/main/ nodejs=10.19.0-r0 npm ; else echo Not installing 10 ; fi
#RUN if [ "$NODE_VERSION" = 12 ] ; then apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/v3.12/main/ nodejs=12.16.3-r1 npm ; else echo Not installing 12 ; fi
RUN if [ "$NODE_VERSION" = 12 ] ; then apk add --no-cache --repository=http://dl-cdn.alpinelinux.org/alpine/v3.11/main/ nodejs=12.15.0-r1 npm ; else echo Not installing 12 ; fi

# Copy wkhtmltopdf from former build stage
COPY --from=wkhtmltopdf /bin/wkhtmltopdf /bin/wkhtmltopdf
COPY --from=wkhtmltopdf /bin/wkhtmltoimage /bin/wkhtmltoimage

# Add user
RUN addgroup -g 1000 -S app \
 && adduser -u 1000 -S app -G app
USER app

# Copy app with gems from former build stage
COPY --from=Builder /usr/local/bundle/ /usr/local/bundle/
COPY --from=Builder --chown=app:app /app /app

#copy jemalloc and update env to use it
COPY --from=builder /usr/local/lib/libjemalloc.so.2 /usr/local/lib/
ENV LD_PRELOAD=/usr/local/lib/libjemalloc.so.2

# Set Rails env
ENV RAILS_LOG_TO_STDOUT true
ENV RAILS_SERVE_STATIC_FILES true
ENV EXECJS_RUNTIME $EXECJS_RUNTIME

WORKDIR /app

# Expose Puma port
EXPOSE ${PORT}

# Save timestamp of image building
RUN date -u > BUILD_TIME

# Start up
ENTRYPOINT ["bin/entrypoint.sh"]

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]