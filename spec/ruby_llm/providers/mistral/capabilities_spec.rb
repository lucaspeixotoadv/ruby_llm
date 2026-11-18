# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::Mistral::Capabilities do
  describe '.supports_reasoning?' do
    it 'recognizes native and adjustable reasoning models' do
      expect(described_class.supports_reasoning?('magistral-small-latest')).to be(true)
      expect(described_class.supports_reasoning?('mistral-small-latest')).to be(true)
      expect(described_class.supports_reasoning?('mistral-medium-3-5')).to be(true)
      expect(described_class.supports_reasoning?('mistral-medium-3.5')).to be(true)
      expect(described_class.supports_reasoning?('pixtral-12b')).to be(false)
    end
  end

  describe '.capabilities_for' do
    it 'detects transcription models' do
      %w[voxtral-mini-transcribe-2507 mistral.voxtral-mini-transcribe-2507].each do |id|
        expect(described_class.capabilities_for(id)).to eq(['transcription'])
      end
    end

    it 'does not treat other voxtral models as transcription' do
      %w[voxtral-small-latest mistral.voxtral-mini-3b-2507].each do |id|
        expect(described_class.capabilities_for(id)).not_to include('transcription')
      end
    end

    it 'does not detect transcription without voxtral before the marker' do
      expect(described_class.capabilities_for('transcribe-voxtral')).not_to include('transcription')
      expect(described_class.capabilities_for('mistral-small-latest')).not_to include('transcription')
    end

    it 'answers long ids with many voxtral occurrences' do
      expect(described_class.capabilities_for("#{'voxtral' * 10_000}a")).not_to include('transcription')
      expect(described_class.capabilities_for("#{'voxtral' * 10_000}transcribe")).to eq(['transcription'])
      expect(described_class.capabilities_for("voxtral#{'a' * 50_000}")).not_to include('transcription')
    end
  end
end
