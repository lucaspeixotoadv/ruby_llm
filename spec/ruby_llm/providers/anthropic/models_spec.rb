# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::Anthropic::Models do
  describe '.parse_list_models_response' do
    let(:response_class) { Struct.new(:body) }

    let(:response) do
      instance_double(
        response_class,
        body: {
          'data' => [
            {
              'id' => 'claude-sonnet-4-5',
              'display_name' => 'Claude Sonnet 4.5',
              'created_at' => '2026-01-02T03:04:05Z'
            }
          ]
        }
      )
    end

    it 'returns minimal provider metadata for models covered by models.dev' do
      model = described_class.parse_list_models_response(
        response,
        'anthropic',
        RubyLLM::Providers::Anthropic::Capabilities
      ).first

      expect(model.id).to eq('claude-sonnet-4-5')
      expect(model.name).to eq('Claude Sonnet 4.5')
      expect(model.provider).to eq('anthropic')
      expect(model.created_at).to eq(Time.parse('2026-01-02T03:04:05Z'))
      expect(model.family).to be_nil
      expect(model.context_window).to be_nil
      expect(model.max_output_tokens).to be_nil
      expect(model.capabilities).to eq([])
      expect(model.pricing.to_h).to eq({})
    end

    # The shape `/v1/models` returns: the full capability tree, with
    # `supported` at every leaf.
    context 'with the capabilities the API describes' do
      def listed(capabilities, max_input_tokens: 1_000_000, max_tokens: 128_000)
        body = { 'data' => [{ 'id' => 'claude-x', 'display_name' => 'Claude X', 'created_at' => '2026-09-22T00:00:00Z',
                              'max_input_tokens' => max_input_tokens, 'max_tokens' => max_tokens,
                              'capabilities' => capabilities }] }
        described_class.parse_list_models_response(instance_double(response_class, body: body), 'anthropic', nil).first
      end

      def thinking(**types)
        { 'supported' => true, 'types' => types.transform_keys(&:to_s).transform_values { |on| { 'supported' => on } } }
      end

      def effort(*levels)
        %w[low medium high xhigh max].to_h { |level| [level, { 'supported' => levels.include?(level) }] }
                                     .merge('supported' => levels.any?)
      end

      it 'reads the context window, the output ceiling and the capabilities' do
        model = listed({ 'image_input' => { 'supported' => true }, 'structured_outputs' => { 'supported' => true },
                         'thinking' => thinking(adaptive: true, enabled: false, disabled: false),
                         'effort' => effort('low', 'medium', 'high', 'xhigh', 'max') })

        expect(model.context_window).to eq(1_000_000)
        expect(model.max_output_tokens).to eq(128_000)
        expect(model.capabilities).to contain_exactly('vision', 'structured_output', 'reasoning')
      end

      # Claude Opus 5.5: adaptive only, and the API refuses `disabled`.
      it 'states the efforts of a model whose thinking cannot be turned off' do
        model = listed({ 'thinking' => thinking(adaptive: true, enabled: false, disabled: false),
                         'effort' => effort('low', 'medium', 'high', 'xhigh', 'max') })

        expect(model.reasoning_options).to eq([{ type: 'effort', values: %w[low medium high xhigh max] }])
      end

      # Claude Haiku 5.5: thinking can be turned off.
      it 'states the toggle when the API takes disabled thinking' do
        model = listed({ 'thinking' => thinking(adaptive: true, enabled: false, disabled: true),
                         'effort' => effort('low', 'medium', 'high', 'xhigh', 'max') })

        expect(model.reasoning_option('toggle')).to eq(type: 'toggle')
      end

      # Claude Haiku 4.5: a thinking budget, and no effort.
      it 'states a budget for a model that takes one, and no effort when it takes none' do
        model = listed({ 'thinking' => thinking(adaptive: false, enabled: true, disabled: true), 'effort' => effort },
                       max_input_tokens: 200_000, max_tokens: 64_000)

        expect(model.reasoning_options).to eq([{ type: 'toggle' }, { type: 'budget_tokens', min: 1024 }])
        expect(model.reasoning_efforts).to eq([])
      end
    end
  end

  describe 'the cache write of a stream event' do
    it 'reads the 1-hour part from the message_start usage' do
      data = { 'type' => 'message_start',
               'message' => { 'usage' => { 'cache_creation_input_tokens' => 248,
                                           'cache_creation' => { 'ephemeral_5m_input_tokens' => 148,
                                                                 'ephemeral_1h_input_tokens' => 100 } } } }

      expect(described_class.extract_cache_creation_tokens(data)).to eq(248)
      expect(described_class.extract_cache_creation_1h_tokens(data)).to eq(100)
    end

    it 'has no 1-hour part when the event does not break the write down' do
      data = { 'type' => 'message_delta', 'usage' => { 'output_tokens' => 5 } }

      expect(described_class.extract_cache_creation_1h_tokens(data)).to be_nil
    end
  end
end
