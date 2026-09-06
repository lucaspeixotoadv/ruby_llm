# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::Gemini::Embeddings do
  # The module is mixed into the provider, so exercise it the way the provider
  # does rather than reaching for the module object.
  let(:embedder) { Object.new.extend(described_class) }
  let(:model) { 'gemini-embedding-001' }

  def payload_for(text, **options)
    embedder.send(:render_embedding_payload, text, model: model, dimensions: nil, **options)
  end

  describe 'a plain embedding' do
    it 'sends only the fields it always sent' do
      request = payload_for('Ruby is a joy')[:requests].first

      expect(request).to eq(
        model: 'models/gemini-embedding-001',
        content: { parts: [{ text: 'Ruby is a joy' }] }
      )
    end

    it 'translates dimensions to outputDimensionality' do
      request = payload_for('Ruby is a joy', dimensions: 1536)[:requests].first

      expect(request[:outputDimensionality]).to eq(1536)
    end

    it 'carries no taskType when the caller stated no task' do
      request = payload_for('Ruby is a joy', dimensions: 1536)[:requests].first

      expect(request).not_to have_key(:taskType)
      expect(request).not_to have_key(:title)
    end
  end

  describe 'a retrieval document' do
    subject(:request) do
      payload_for('Refunds are issued within 30 days',
                  dimensions: 1536,
                  task: :retrieval_document,
                  title: 'Refund policy')[:requests].first
    end

    it 'asks for a document embedding' do
      expect(request[:taskType]).to eq('RETRIEVAL_DOCUMENT')
    end

    it 'keeps the requested width' do
      expect(request[:outputDimensionality]).to eq(1536)
    end

    it 'passes the title the caller gave' do
      expect(request[:title]).to eq('Refund policy')
    end
  end

  describe 'a retrieval query' do
    subject(:request) do
      payload_for('how long do refunds take?', dimensions: 1536, task: :retrieval_query)[:requests].first
    end

    it 'asks for a query embedding' do
      expect(request[:taskType]).to eq('RETRIEVAL_QUERY')
    end

    it 'keeps the requested width' do
      expect(request[:outputDimensionality]).to eq(1536)
    end

    it 'sends no title' do
      expect(request).not_to have_key(:title)
    end
  end

  it 'applies the task to every text in a batch' do
    requests = payload_for(%w[chunk-one chunk-two], task: :retrieval_document, title: 'Handbook')[:requests]

    expect(requests.map { |r| r[:taskType] }).to eq(%w[RETRIEVAL_DOCUMENT RETRIEVAL_DOCUMENT])
    expect(requests.map { |r| r[:title] }).to eq(%w[Handbook Handbook])
  end

  it 'accepts an already-coerced task, as Provider#embed hands one over' do
    request = payload_for('hi', task: RubyLLM::Embedding::Task.from(:semantic_similarity))[:requests].first

    expect(request[:taskType]).to eq('SEMANTIC_SIMILARITY')
  end

  describe RubyLLM::Providers::Gemini::Capabilities do
    it 'lets gemini-embedding-001 be asked for any documented task' do
      expect(described_class.embedding_tasks_for('gemini-embedding-001'))
        .to match_array(RubyLLM::Embedding::Task::NAMES)
    end

    it 'reports no tasks for the gemini-embedding-2 family, which dropped the parameter' do
      expect(described_class.embedding_tasks_for('gemini-embedding-2')).to be_empty
      expect(described_class.embedding_tasks_for('gemini-embedding-2-preview')).to be_empty
    end

    it 'reports no tasks for the legacy embedding-001, which predates it' do
      expect(described_class.embedding_tasks_for('embedding-001')).to be_empty
    end

    it 'keeps task support for the text-embedding models' do
      expect(described_class.embedding_tasks_for('text-embedding-004')).to include(:retrieval_document)
      expect(described_class.embedding_tasks_for('text-embedding-005')).to include(:retrieval_query)
    end

    it 'says nothing about a model that does not embed' do
      expect(described_class.embedding_tasks_for('gemini-2.5-flash')).to be_empty
    end
  end

  describe '.task_type_for' do
    it 'spells a task the way the Gemini taskType enum does' do
      expect(described_class.task_type_for(:code_retrieval_query)).to eq('CODE_RETRIEVAL_QUERY')
    end

    it 'has nothing to send when there is no task' do
      expect(described_class.task_type_for(nil)).to be_nil
    end
  end
end
