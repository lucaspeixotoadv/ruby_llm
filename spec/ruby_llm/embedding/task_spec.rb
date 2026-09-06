# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Embedding::Task do
  describe '.from' do
    it 'accepts a RubyLLM task name' do
      expect(described_class.from(:retrieval_document).to_sym).to eq(:retrieval_document)
    end

    it 'accepts a string' do
      expect(described_class.from('retrieval_query').to_sym).to eq(:retrieval_query)
    end

    it "accepts a provider's own spelling of the same task" do
      expect(described_class.from('RETRIEVAL_DOCUMENT').to_sym).to eq(:retrieval_document)
    end

    it 'passes a task through unchanged' do
      task = described_class.from(:clustering)

      expect(described_class.from(task)).to be(task)
    end

    it 'reads nil as no task at all' do
      expect(described_class.from(nil)).to be_nil
    end

    it 'rejects a task nobody supports, naming the ones that exist' do
      expect { described_class.from(:retrieve_document) }
        .to raise_error(RubyLLM::InvalidEmbeddingTaskError, /Unknown embedding task .*retrieval_document/m)
    end
  end

  describe '#accepts_title?' do
    it 'is true for a document, the only thing a title describes' do
      expect(described_class.from(:retrieval_document)).to be_accepts_title
    end

    it 'is false for a query' do
      expect(described_class.from(:retrieval_query)).not_to be_accepts_title
    end
  end

  describe '.coerce' do
    it 'keeps a title that belongs to a document embedding' do
      expect(described_class.coerce(:retrieval_document, title: 'Refund policy').to_sym)
        .to eq(:retrieval_document)
    end

    it 'refuses a title on a query, which the provider would ignore' do
      expect { described_class.coerce(:retrieval_query, title: 'Refund policy') }
        .to raise_error(RubyLLM::InvalidEmbeddingTaskError, /only meaningful/)
    end

    it 'refuses a title with no task at all' do
      expect { described_class.coerce(nil, title: 'Refund policy') }
        .to raise_error(RubyLLM::InvalidEmbeddingTaskError, /only meaningful/)
    end

    it 'leaves a plain embedding untouched' do
      expect(described_class.coerce(nil)).to be_nil
    end
  end

  it 'names every task type the Gemini embedding API documents' do
    expect(described_class::NAMES).to contain_exactly(
      :retrieval_document, :retrieval_query, :semantic_similarity, :classification,
      :clustering, :question_answering, :fact_verification, :code_retrieval_query
    )
  end
end
