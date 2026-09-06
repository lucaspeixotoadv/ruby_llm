# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Providers::VertexAI::Embeddings do
  let(:embedder) { Object.new.extend(described_class) }

  def instances_for(text, **options)
    embedder.send(:render_embedding_payload, text, model: 'text-embedding-005', dimensions: nil, **options)
  end

  it 'sends bare instances for a plain embedding' do
    expect(instances_for('Ruby is a joy')).to eq(instances: [{ content: 'Ruby is a joy' }])
  end

  it 'carries the task and the title on the instance, as the Vertex SDK does' do
    payload = instances_for('Refunds take 30 days', dimensions: 768,
                                                    task: :retrieval_document, title: 'Refund policy')

    expect(payload[:instances].first)
      .to eq(content: 'Refunds take 30 days', task_type: 'RETRIEVAL_DOCUMENT', title: 'Refund policy')
    expect(payload[:parameters]).to eq(outputDimensionality: 768)
  end

  it 'sends no title for a query' do
    payload = instances_for('how long do refunds take?', task: :retrieval_query)

    expect(payload[:instances].first).to eq(content: 'how long do refunds take?', task_type: 'RETRIEVAL_QUERY')
  end
end
