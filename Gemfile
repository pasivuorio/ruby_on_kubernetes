source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '2.7.1'

# Bundle latest Rails
gem 'rails'
# Use postgress as database
gem 'pg'
# Use Puma as the app server
gem 'puma'
# Use SCSS for stylesheets
gem 'sass-rails'
# Transpile app-like JavaScript. Read more: https://github.com/rails/webpacker
gem 'webpacker'
# Turbolinks makes navigating your web application faster. Read more: https://github.com/turbolinks/turbolinks
gem 'turbolinks', '~> 5'
# Use Sidekiq and Redis as as job queue
gem 'redis'
gem 'sidekiq'
# Include image processing (imagemagick, vips) capabilities
gem 'image_processing'
# Use elasticsearch and APM
gem 'elasticsearch'
gem 'elastic-apm'
gem 'elasticsearch-rails'
gem 'elasticsearch-model'
gem 'elasticsearch-persistence'

# Reduces boot times through caching; required in config/boot.rb
gem 'bootsnap', '>= 1.4.2', require: false
gem "dotenv", "~> 2.7"
gem 'public_suffix'

#use AWS sdk to setup S3-compatible buckets
gem 'aws-sdk-s3'
gem 'stomp'

group :development, :test do
  # Call 'byebug' anywhere in the code to stop execution and get a debugger console
  gem 'byebug', platforms: [:mri, :mingw, :x64_mingw]
end

group :development do
  # Access an interactive console on exception pages or by calling 'console' anywhere in the code.
  gem 'web-console', '>= 3.3.0'
  gem 'listen', '~> 3.2'
  # Spring speeds up development by keeping your application running in the background. Read more: https://github.com/rails/spring
  gem 'spring'
  gem 'spring-watcher-listen', '~> 2.0.0'

  #gems for managing cluster, only available in development environment
  gem "droplet_kit", "~> 3.8"
end

group :test do
  # Adds support for Capybara system testing and selenium driver
  gem 'capybara', '>= 2.15'
  gem 'selenium-webdriver'
  # Easy installation and use of web drivers to run system tests with browsers
  gem 'webdrivers'
end


