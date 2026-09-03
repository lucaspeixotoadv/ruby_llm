# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::OpenAI::Temperature do
  def model(id, temperature: :unstated)
    metadata = temperature == :unstated ? {} : { temperature: temperature }
    RubyLLM::Model::Info.new(id: id, provider: 'openai', metadata: metadata)
  end

  describe '.normalize' do
    it 'keeps a temperature the registry says the model supports' do
      expect(described_class.normalize(0.7, model('gpt-4o', temperature: true))).to eq(0.7)
    end

    it 'omits the temperature the registry says the model refuses' do
      expect(described_class.normalize(0.7, model('gpt-5', temperature: false))).to be_nil
    end

    it 'omits rather than rewriting a refused temperature to 1.0' do
      # The old behaviour answered a different question than the caller asked:
      # 0.2 arrived at the API as 1.0. Leaving the parameter out lets the
      # model's own default stand and keeps the request honest.
      expect(described_class.normalize(0.2, model('o3', temperature: false))).to be_nil
    end

    it 'sends the temperature unchanged when the registry states nothing' do
      # Silence is not a refusal. Dated snapshots and preview ids reach the
      # registry from the provider listing alone and carry no temperature field.
      expect(described_class.normalize(0.7, model('gpt-5-2025-08-07'))).to eq(0.7)
    end

    it 'leaves an unset temperature unset' do
      expect(described_class.normalize(nil, model('gpt-5', temperature: false))).to be_nil
      expect(described_class.normalize(nil, model('gpt-4o', temperature: true))).to be_nil
    end

    it 'does not classify by model id' do
      # Same family, opposite registry answers: an id-shaped rule cannot tell
      # these apart, and the previous regex sent gpt-5-mini a temperature the
      # API refuses.
      refusing = %w[gpt-5 gpt-5-mini gpt-5-nano gpt-5-codex gpt-5.4-pro o1-mini]
      accepting = %w[gpt-5-chat-latest gpt-5.3-chat-latest o1-preview]

      expect(refusing.map { |id| described_class.normalize(0.7, model(id, temperature: false)) }).to all(be_nil)
      expect(accepting.map { |id| described_class.normalize(0.7, model(id, temperature: true)) }).to all(eq(0.7))
    end

    it 'passes the temperature through for anything that cannot state the capability' do
      expect(described_class.normalize(0.7, 'gpt-5')).to eq(0.7)
    end
  end

  describe 'against the shipped registry' do
    let(:models) { RubyLLM::Models.new }

    def normalize_for(id, provider: 'openai')
      described_class.normalize(0.7, models.find(id, provider))
    end

    it 'omits the temperature for the gpt-5 variants the old regex missed' do
      expect(normalize_for('gpt-5-mini')).to be_nil
      expect(normalize_for('gpt-5-nano')).to be_nil
      expect(normalize_for('gpt-5')).to be_nil
    end

    it 'keeps the temperature for the chat variants that accept one' do
      expect(normalize_for('gpt-5-chat-latest')).to eq(0.7)
      expect(normalize_for('gpt-4o')).to eq(0.7)
    end

    it 'follows the registry for OpenAI-compatible providers too' do
      expect(normalize_for('openai/gpt-5-mini', provider: 'openrouter')).to be_nil
      expect(normalize_for('grok-4', provider: 'xai')).to eq(0.7)
    end
  end
end
