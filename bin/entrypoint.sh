#! /bin/sh

#!/bin/bash use sh instead

# If database exists, migrate. Otherwise create and seed
bundle exec rake db:migrate 2>/dev/null || bundle exec rake db:create db:migrate db:seed
# if folders dont exist, create them
mkdir tmp
mkdir tmp/pids
# Remove a potentially pre-existing server.pid for Rails.
rm -f ./tmp/pids/server.pid

# Then exec the container's main process (what's set as CMD in the Dockerfile).
exec "$@"