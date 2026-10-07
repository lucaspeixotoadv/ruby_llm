# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::Anthropic do
  subject(:provider) { described_class.new(config) }

  let(:config) do
    instance_double(
      RubyLLM::Configuration,
      request_timeout: 300,
      max_retries: 3,
      retry_interval: 0.1,
      retry_interval_randomness: 0.5,
      retry_backoff_factor: 2,
      http_proxy: nil,
      anthropic_api_key: 'test-key',
      anthropic_api_base: anthropic_api_base
    )
  end

  describe '#api_base' do
    context 'when anthropic_api_base is not set' do
      let(:anthropic_api_base) { nil }

      it 'returns the default Anthropic API URL' do
        expect(provider.api_base).to eq('https://api.anthropic.com')
      end
    end

    context 'when anthropic_api_base is set' do
      let(:anthropic_api_base) { 'https://custom-anthropic-endpoint.example.com' }

      it 'returns the custom API URL' do
        expect(provider.api_base).to eq('https://custom-anthropic-endpoint.example.com')
      end
    end
  end

  # Current Claude models answer 400 to any temperature; the registry says so.
  describe 'temperature' do
    let(:anthropic_api_base) { nil }

    def model(temperature)
      RubyLLM::Model::Info.new(id: 'claude-x', provider: 'anthropic', metadata: { temperature: temperature })
    end

    it 'leaves out a temperature the model refuses' do
      expect(provider.send(:maybe_normalize_temperature, 0.2, model(false))).to be_nil
    end

    it 'keeps a temperature the model takes' do
      expect(provider.send(:maybe_normalize_temperature, 0.2, model(true))).to eq(0.2)
    end
  end
end
