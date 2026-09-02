# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Model::EmbeddingDimensions do
  describe '.from' do
    it 'returns nil for a model that has none' do
      expect(described_class.from(nil)).to be_nil
    end

    it 'reads a bare integer as a fixed width' do
      dimensions = described_class.from(1536)

      expect(dimensions.default).to eq(1536)
      expect(dimensions).not_to be_configurable
      expect(dimensions.supported).to eq([1536])
    end

    it 'accepts string keys, as a JSON or jsonb round-trip delivers them' do
      dimensions = described_class.from('default' => 3072, 'configurable' => true, 'max' => 3072)

      expect(dimensions.default).to eq(3072)
      expect(dimensions).to be_configurable
      expect(dimensions.max).to eq(3072)
    end

    it 'passes an existing instance through' do
      dimensions = described_class.new(default: 768)

      expect(described_class.from(dimensions)).to be(dimensions)
    end

    it 'returns nil rather than a zero-width vector for junk' do
      expect(described_class.from({})).to be_nil
      expect(described_class.from(default: 0)).to be_nil
      expect(described_class.from('nope')).to be_nil
    end
  end

  describe 'a fixed-width model' do
    subject(:dimensions) { described_class.new(default: 1024, configurable: false) }

    it 'is not configurable' do
      expect(dimensions).not_to be_configurable
      expect(dimensions).to be_fixed
    end

    it 'supports only its own width' do
      expect(dimensions.supports?(1024)).to be true
      expect(dimensions.supports?(512)).to be false
    end

    it 'serializes without inventing a range' do
      expect(dimensions.to_h).to eq(default: 1024, configurable: false)
    end
  end

  describe 'a Matryoshka model with a documented range and recommended sizes' do
    subject(:dimensions) do
      described_class.new(default: 3072, configurable: true, supported: [768, 1536, 3072], min: 128, max: 3072)
    end

    it 'keeps the default distinct from the sizes it also accepts' do
      expect(dimensions.default).to eq(3072)
      expect(dimensions.supported).to eq([768, 1536, 3072])
      expect(dimensions).to be_configurable
    end

    it 'accepts any width inside the documented range, not just the listed ones' do
      expect(dimensions.supports?(768)).to be true
      expect(dimensions.supports?(512)).to be true
      expect(dimensions.supports?(128)).to be true
    end

    it 'rejects widths outside the documented range' do
      expect(dimensions.supports?(127)).to be false
      expect(dimensions.supports?(4096)).to be false
      expect(dimensions.supports?(0)).to be false
      expect(dimensions.supports?(nil)).to be false
    end
  end

  describe 'a model with a discrete list and no documented range' do
    subject(:dimensions) { described_class.new(default: 1024, configurable: true, supported: [256, 512, 1024]) }

    it 'accepts the listed widths' do
      expect(dimensions.supports?(256)).to be true
      expect(dimensions.supports?(1024)).to be true
    end

    it 'refuses a width the provider never listed' do
      expect(dimensions.supports?(700)).to be false
    end
  end

  describe 'a configurable model whose provider documents no bounds' do
    subject(:dimensions) { described_class.new(default: 1536, configurable: true) }

    it 'does not claim a range it was not given' do
      expect(dimensions.min).to be_nil
      expect(dimensions.max).to be_nil
      expect(dimensions.to_h).to eq(default: 1536, configurable: true)
    end

    it 'accepts any positive width rather than inventing a ceiling' do
      expect(dimensions.supports?(256)).to be true
      expect(dimensions.supports?(4096)).to be true
      expect(dimensions.supports?(-1)).to be false
    end
  end

  describe 'inference when configurable is not stated' do
    it 'infers configurable from more than one supported width' do
      expect(described_class.new(default: 1024, supported: [256, 1024])).to be_configurable
    end

    it 'infers configurable from a min/max range' do
      expect(described_class.new(default: 768, min: 128, max: 768)).to be_configurable
    end

    it 'infers fixed when there is only a single width' do
      expect(described_class.new(default: 768)).to be_fixed
    end
  end

  describe '#to_h' do
    it 'round-trips through JSON without losing anything' do
      dimensions = described_class.new(default: 3072, configurable: true, supported: [768, 3072], min: 128, max: 3072)
      round_tripped = described_class.from(JSON.parse(JSON.generate(dimensions.to_h)))

      expect(round_tripped).to eq(dimensions)
    end

    it 'omits a supported list that only repeats the default' do
      expect(described_class.new(default: 768).to_h).to eq(default: 768, configurable: false)
    end
  end

  describe '.from_capabilities' do
    it 'asks a capabilities module that knows about widths' do
      capabilities = Class.new do
        def self.embedding_dimensions_for(_model_id) = { default: 1024 }
      end

      expect(described_class.from_capabilities(capabilities, 'anything')).to eq(default: 1024)
    end

    it 'stays quiet for a capabilities module that has nothing to say' do
      capabilities = Class.new do
        def self.max_tokens_for(_model_id) = 4096
      end

      expect(described_class.from_capabilities(capabilities, 'anything')).to be_nil
    end
  end
end
