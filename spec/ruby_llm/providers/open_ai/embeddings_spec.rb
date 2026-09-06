# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::OpenAI::Embeddings do
  def payload_for(text, model:, **options)
    described_class.render_embedding_payload(text, model: model, dimensions: nil, **options)
  end

  it 'sends model and input for a plain embedding' do
    expect(payload_for('Ruby is a joy', model: 'text-embedding-3-small'))
      .to eq(model: 'text-embedding-3-small', input: 'Ruby is a joy')
  end

  it 'omits dimensions rather than sending null' do
    expect(payload_for('Ruby is a joy', model: 'text-embedding-3-small')).not_to have_key(:dimensions)
  end

  it 'asks text-embedding-3-small for a narrower vector' do
    expect(payload_for('Ruby is a joy', model: 'text-embedding-3-small', dimensions: 512))
      .to eq(model: 'text-embedding-3-small', input: 'Ruby is a joy', dimensions: 512)
  end

  it 'asks text-embedding-3-large for 1536 dimensions' do
    expect(payload_for('Ruby is a joy', model: 'text-embedding-3-large', dimensions: 1536))
      .to eq(model: 'text-embedding-3-large', input: 'Ruby is a joy', dimensions: 1536)
  end

  it 'batches an array of texts as a single input' do
    expect(payload_for(%w[Ruby Python], model: 'text-embedding-3-small')[:input]).to eq(%w[Ruby Python])
  end

  # The OpenAI embeddings endpoint has no task or title parameter, so adding
  # them to the RubyLLM abstraction must leave this payload exactly as it was.
  it 'gained no fields from the Gemini task support' do
    expect(payload_for('Ruby is a joy', model: 'text-embedding-3-large', dimensions: 1536).keys)
      .to contain_exactly(:model, :input, :dimensions)
  end
end
