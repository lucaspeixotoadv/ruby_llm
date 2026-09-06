# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Embedding do
  include_context 'with configured RubyLLM'

  let(:test_text) { "Ruby is a programmer's best friend" }
  let(:test_texts) { %w[Ruby Python JavaScript] }
  let(:test_dimensions) { 768 }

  describe 'basic functionality' do
    EMBEDDING_MODELS.each do |config|
      provider = config[:provider]
      model = config[:model]
      it "#{provider}/#{model} can handle a single text" do
        embedding = RubyLLM.embed(test_text, model: model, provider: provider)
        expect(embedding.vectors).to be_an(Array)
        expect(embedding.vectors.first).to be_a(Float)
        expect(embedding.model).to eq(model)
        # Providers that report usage must report something sane; providers
        # that report none leave it unknown rather than claiming zero.
        expect(embedding.input_tokens).to be >= 0 if embedding.input_tokens?
      end

      it "#{provider}/#{model} can handle a single text with custom dimensions" do
        skip 'Mistral does not support custom dimensions' if provider == :mistral
        skip 'Azure Cohere embeddings do not support custom dimensions' if provider == :azure

        embedding = RubyLLM.embed(test_text, model: model, provider: provider, dimensions: test_dimensions)
        expect(embedding.vectors).to be_an(Array)
        expect(embedding.vectors.length).to eq(test_dimensions)
      end

      it "#{provider}/#{model} can handle multiple texts" do
        embeddings = RubyLLM.embed(test_texts, model: model)
        expect(embeddings.vectors).to be_an(Array)
        expect(embeddings.vectors.size).to eq(3)
        expect(embeddings.vectors.first).to be_an(Array)
        expect(embeddings.model).to eq(model)
        expect(embeddings.input_tokens).to be >= 0 if embeddings.input_tokens?
      end

      it "#{provider}/#{model} can handle multiple texts with custom dimensions" do
        skip 'Mistral does not support custom dimensions' if provider == :mistral
        skip 'Azure Cohere embeddings do not support custom dimensions' if provider == :azure

        embeddings = RubyLLM.embed(test_texts, model: model, provider: provider, dimensions: test_dimensions)
        expect(embeddings.vectors).to be_an(Array)
        embeddings.vectors.each do |vector|
          expect(vector.length).to eq(test_dimensions)
        end
      end

      it "#{provider}/#{model} handles single-string arrays consistently" do
        embeddings = RubyLLM.embed(['Ruby is great'], model: model, provider: provider)
        expect(embeddings.vectors).to be_an(Array)
        expect(embeddings.vectors.size).to eq(1)
        expect(embeddings.vectors.first).to be_an(Array)
        expect(embeddings.vectors.first.first).to be_a(Float)
      end
    end
  end

  # Recorded against the live API: proof that the request RubyLLM builds for a
  # retrieval task is one Gemini accepts, at the width that was asked for.
  describe 'retrieval embeddings' do
    it 'gemini/gemini-embedding-001 embeds a titled document at a reduced width' do
      embedding = RubyLLM.embed('Refunds are issued within 30 days of purchase.',
                                model: 'gemini-embedding-001', provider: :gemini,
                                dimensions: 1536, task: :retrieval_document, title: 'Refund policy')

      expect(embedding.vectors).to be_an(Array)
      expect(embedding.vectors.length).to eq(1536)
      expect(embedding.vectors.first).to be_a(Float)
    end

    it 'gemini/gemini-embedding-001 embeds a query at the same width' do
      embedding = RubyLLM.embed('how long do refunds take?',
                                model: 'gemini-embedding-001', provider: :gemini,
                                dimensions: 1536, task: :retrieval_query)

      expect(embedding.vectors).to be_an(Array)
      expect(embedding.vectors.length).to eq(1536)
    end
  end

  # These reach the provider object but never the network: an embedding that
  # cannot be honoured is rejected before a request is built.
  describe 'retrieval tasks' do
    let(:embedding) { described_class.new(vectors: [0.1, 0.2], model: 'gemini-embedding-001') }

    def stub_provider(slug)
      model_info = instance_double(RubyLLM::Model::Info, id: 'gemini-embedding-001', provider: slug)
      provider = instance_double(RubyLLM::Provider, slug: slug.to_s)
      allow(provider).to receive(:embed).and_return(embedding)
      allow(RubyLLM::Models).to receive(:resolve).and_return([model_info, provider])
      provider
    end

    it 'hands the task and the title to the provider' do
      provider = stub_provider(:gemini)

      RubyLLM.embed('Refunds take 30 days', model: 'gemini-embedding-001', dimensions: 1536,
                                            task: :retrieval_document, title: 'Refund policy')

      expect(provider).to have_received(:embed).with(
        'Refunds take 30 days',
        model: 'gemini-embedding-001',
        dimensions: 1536,
        task: RubyLLM::Embedding::Task.from(:retrieval_document),
        title: 'Refund policy'
      )
    end

    it 'states no task when the caller states none' do
      provider = stub_provider(:gemini)

      RubyLLM.embed('Ruby is great', model: 'gemini-embedding-001')

      expect(provider).to have_received(:embed).with(
        'Ruby is great', model: 'gemini-embedding-001', dimensions: nil, task: nil, title: nil
      )
    end

    it 'rejects a task no provider knows before resolving a model' do
      expect { RubyLLM.embed('Ruby is great', model: 'gemini-embedding-001', task: :retrieve) }
        .to raise_error(RubyLLM::InvalidEmbeddingTaskError)
    end

    it 'rejects a title that no task can carry' do
      expect { RubyLLM.embed('Ruby is great', model: 'gemini-embedding-001', title: 'Refund policy') }
        .to raise_error(RubyLLM::InvalidEmbeddingTaskError)
    end

    it 'refuses to pretend OpenAI can embed for a task' do
      expect do
        RubyLLM.embed('how long do refunds take?', model: 'text-embedding-3-small', provider: :openai,
                                                   task: :retrieval_query)
      end.to raise_error(RubyLLM::UnsupportedEmbeddingTaskError, /takes no task types/)
    end

    it 'refuses a task on a Gemini model that dropped the parameter' do
      expect do
        RubyLLM.embed('how long do refunds take?', model: 'gemini-embedding-2', provider: :gemini,
                                                   task: :retrieval_query)
      end.to raise_error(RubyLLM::UnsupportedEmbeddingTaskError, /gemini-embedding-2/)
    end
  end
end
