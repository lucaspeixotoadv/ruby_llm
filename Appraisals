# frozen_string_literal: true

appraise 'rails-7.1' do
  group :development do
    gem 'rails', '~> 7.1.0'
    # ActiveSupport 7.1 passes `quirks_mode:` to JSON, which json 3 removed.
    gem 'json', '< 3'
  end
end

appraise 'rails-7.2' do
  group :development do
    gem 'rails', '~> 7.2.0'
  end
end

appraise 'rails-8.0' do
  group :development do
    gem 'rails', '~> 8.0.0'
  end
end

appraise 'rails-8.1' do
  group :development do
    gem 'rails', '~> 8.1.0'
  end
end
