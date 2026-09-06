---
layout: default
title: Embeddings
nav_order: 4
description: Transform text into numerical vectors for semantic search, recommendations, and content similarity
redirect_from:
  - /guides/embeddings
---

# {{ page.title }}
{: .no_toc }

{{ page.description }}
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

After reading this guide, you will know:

*   How to generate embeddings for single or multiple texts.
*   How to choose specific embedding models.
*   How to request a specific number of dimensions.
*   How to tell RubyLLM whether you are embedding a document or a search query.
*   How to use the results, including calculating similarity.
*   Which of this each provider actually supports, and what normalization you owe your vectors.
*   How to handle errors during embedding generation.
*   Best practices for performance and large datasets.
*   How to integrate embeddings in a Rails application.

## Basic Embedding Generation

The simplest way to create an embedding is with the global `RubyLLM.embed` method:

```ruby
# Create an embedding for a single text
embedding = RubyLLM.embed("Ruby is a programmer's best friend")

# The vector representation (an array of floats)
vector = embedding.vectors
puts "Vector dimension: #{vector.length}" # e.g., 1536 for {{ site.models.embedding_small }}

# Access metadata
puts "Model used: #{embedding.model}"
puts "Input tokens: #{embedding.input_tokens}"
```

## Embedding Multiple Texts

You can efficiently embed multiple texts in a single API call:

```ruby
texts = ["Ruby", "Python", "JavaScript"]
embeddings = RubyLLM.embed(texts)

# Each text gets its own vector within the `vectors` array
puts "Number of vectors: #{embeddings.vectors.length}" # => 3
puts "First vector dimensions: #{embeddings.vectors.first.length}"
puts "Model used: #{embeddings.model}"
puts "Total input tokens: #{embeddings.input_tokens}"
```

> Batching multiple texts is generally more performant and cost-effective than making individual requests for each text.
{: .note }

## Choosing Models

By default, RubyLLM uses a capable default embedding model (like OpenAI's `{{ site.models.embedding_small }}`), but you can specify a different one using the `model:` argument.

```ruby
# Use a specific OpenAI model
embedding_large = RubyLLM.embed(
  "This is a test sentence",
  model: "{{ site.models.embedding_large }}"
)

# Or use a Google model
embedding_google = RubyLLM.embed(
  "This is another test sentence",
  model: "{{ site.models.embedding_google }}" # Google's model
)

# Use a model not in the registry (useful for custom endpoints)
embedding_custom = RubyLLM.embed(
  "Custom model test",
  model: "my-custom-embedding-model",
  provider: :openai,
  assume_model_exists: true
)
```

You can configure the default embedding model globally:

```ruby
RubyLLM.configure do |config|
  config.default_embedding_model = "{{ site.models.embedding_large }}"
end
```

Refer to the [Working with Models Guide]({% link _advanced/models.md %}) for details on finding available embedding models and their capabilities.

## Choosing Dimensions

Each embedding model has its own default output dimensions. For example, OpenAI's `{{ site.models.embedding_small }}` outputs 1536 dimensions by default, while `{{ site.models.embedding_large }}` outputs 3072 dimensions. RubyLLM allows you to specify these dimensions per request:

```ruby
embedding = RubyLLM.embed(
  "This is a test sentence",
  model: "{{ site.models.embedding_small }}",
  dimensions: 512
)
```

This is particularly useful when:
- Working with vector databases that have specific dimension requirements
- Ensuring consistent dimensionality across different requests
- Optimizing storage and query performance in your vector database

RubyLLM sends `dimensions:` to whichever parameter the provider actually publishes:

| Provider | Wire parameter | Models that accept it |
| :------- | :------------- | :-------------------- |
| OpenAI | `dimensions` | `text-embedding-3-small` (native 1536), `text-embedding-3-large` (native 3072). `text-embedding-ada-002` has no such parameter. |
| Gemini | `outputDimensionality` | `gemini-embedding-001` and the `gemini-embedding-2` family (native 3072; Google recommends 768, 1536 or 3072), `text-embedding-004/005`. The legacy `embedding-001` has no such parameter. |
| Vertex AI | `parameters.outputDimensionality` | Same models, through the `:predict` endpoint. |

A model with no dimensions parameter ignores the request and returns its native width. Ask a model's registry entry what it can do rather than guessing:

```ruby
model = RubyLLM.models.find("{{ site.models.embedding_large }}")
model.embedding_dimensions.default      # => 3072
model.embedding_dimensions.configurable? # => true
model.embedding_dimensions.supports?(1536) # => true
```

## Documents and Queries: Stating What an Embedding Is For

A document you are indexing and a query you will search it with are not the same kind of text, and some providers produce different - asymmetric - vectors for each. Only your application knows which side it is on, so tell RubyLLM with `task:`:

```ruby
# Indexing a document
document = RubyLLM.embed(
  "Refunds are issued within 30 days of purchase.",
  model: "gemini-embedding-001",
  dimensions: 1536,
  task: :retrieval_document,
  title: "Refund policy"
)

# Searching for it later
query = RubyLLM.embed(
  "how long do refunds take?",
  model: "gemini-embedding-001",
  dimensions: 1536,
  task: :retrieval_query
)
```

`task:` is optional. A call that omits it behaves exactly as it always has, and both sides of a retrieval system embedded without a task still work - they are simply general-purpose vectors rather than retrieval-tuned ones.

The task names RubyLLM understands:

| Task | What it is for |
| :--- | :------------- |
| `:retrieval_document` | A document being indexed for later search. The only task that takes a `title:`. |
| `:retrieval_query` | A query searching over those documents. |
| `:semantic_similarity` | Comparing two texts for likeness. |
| `:classification` | Text that will feed a classifier. |
| `:clustering` | Text that will be grouped without labels. |
| `:question_answering` | Question answering. |
| `:fact_verification` | Fact verification. |
| `:code_retrieval_query` | A query searching over code. |

Index and search must agree: embed your corpus with `:retrieval_document` and your queries with `:retrieval_query`. Mixing a document-tuned index with query-tuned lookups (or vice versa) quietly degrades results.

### Titles

`title:` is the document's own title, supplied by you - RubyLLM never derives one from the text. Google states that a title produces better-quality retrieval embeddings, and that it applies only to `RETRIEVAL_DOCUMENT`. RubyLLM enforces the same rule:

```ruby
RubyLLM.embed("...", model: "gemini-embedding-001", task: :retrieval_query, title: "Refund policy")
# => RubyLLM::InvalidEmbeddingTaskError: title: is only meaningful for an embedding task
#    that describes a document (retrieval_document), got :retrieval_query.
```

When you batch several texts in one call, the title applies to all of them - right for chunks of a single document, wrong for chunks of different ones. Embed different documents in different calls if each needs its own title.

### Provider Support

`task:` is refused, not ignored, when the chosen model cannot honour it - otherwise you would store general-purpose vectors believing they were tuned for retrieval:

```ruby
RubyLLM.embed("...", model: "{{ site.models.embedding_small }}", task: :retrieval_query)
# => RubyLLM::UnsupportedEmbeddingTaskError: openai/text-embedding-3-small cannot embed for
#    the retrieval_query task. This model takes no task types; omit task: and title:.
```

| Provider / model | Task support |
| :--------------- | :----------- |
| Gemini `gemini-embedding-001`, `text-embedding-004/005`, `text-multilingual-embedding-002` | All tasks above, sent as `taskType` (plus `title` for documents). |
| Vertex AI, same models | All tasks above, sent as each instance's `task_type` and `title`. |
| Gemini `gemini-embedding-2` family | None. Google dropped the parameter for these models; state the task in the text itself instead. The API still *accepts* a `taskType` and returns a byte-identical vector with or without it, so RubyLLM refuses it rather than let it look honoured. |
| Gemini `embedding-001` (legacy) | None. Predates the parameter. |
| OpenAI, Mistral, Azure | None. Their embedding endpoints have no equivalent, and their vectors are symmetric - use the same call for documents and queries. |

## Normalization

Whether a vector arrives with unit length depends on the provider, and RubyLLM does not silently rescale what a provider returns:

*   **OpenAI** normalizes its embeddings to length 1, including after `dimensions:` shortens them. Cosine similarity and dot product agree; nothing is owed by you.
*   **Gemini `gemini-embedding-001`** returns normalized vectors only at its native 3072. Ask for a reduced width and the truncated vector is **not** re-normalized - you must do it before comparing vectors, or cosine similarity will be wrong. Measured against the live API: ‖v‖ = 1.0 at 3072, 0.70 at 1536, 0.58 at 768.
*   **Gemini `gemini-embedding-2`** normalizes at every width, reduced ones included (‖v‖ = 1.0 at 768). Nothing is owed by you.

```ruby
# Required for gemini-embedding-001 at any width other than its native 3072
def normalize(vector)
  norm = Math.sqrt(vector.sum { |value| value * value })
  norm.zero? ? vector : vector.map { |value| value / norm }
end

embedding = RubyLLM.embed(text, model: "gemini-embedding-001", dimensions: 1536, task: :retrieval_document)
vectors = normalize(embedding.vectors)
```

Normalize both sides consistently - documents at index time and queries at search time - and store the normalized form so your database compares like with like.

## Using Embedding Results

### Vector Properties

The embedding result contains useful information:

```ruby
embedding = RubyLLM.embed("Example text")

# The vector representation
puts embedding.vectors.class  # => Array
puts embedding.vectors.first.class  # => Float

# The vector dimensions
puts embedding.vectors.first.length # => 1536

# The model used
puts embedding.model  # => "{{ site.models.embedding_small }}"
```

## Using Embedding Results

A primary use case for embeddings is measuring the semantic similarity between texts. Cosine similarity is a common metric.

```ruby
require 'matrix' # Ruby's built-in Vector class requires 'matrix'

embedding1 = RubyLLM.embed("I love Ruby programming")
embedding2 = RubyLLM.embed("Ruby is my favorite language")

# Convert embedding vectors to Ruby Vector objects
vector1 = Vector.elements(embedding1.vectors)
vector2 = Vector.elements(embedding2.vectors)

# Calculate cosine similarity (value between -1 and 1, closer to 1 means more similar)
similarity = vector1.inner_product(vector2) / (vector1.norm * vector2.norm)
puts "Similarity: #{similarity.round(4)}" # => e.g., 0.9123
```

## Error Handling

Embedding API calls can fail for various reasons. Handle errors gracefully:

```ruby
begin
  embedding = RubyLLM.embed("Your text here")
  # Process embedding...
rescue RubyLLM::Error => e
  # Handle API errors
  puts "Embedding failed: #{e.message}"
end
```

For comprehensive error handling patterns and retry strategies, see the [Error Handling Guide]({% link _advanced/error-handling.md %}).

## Performance and Best Practices

*   **Batching:** Always embed multiple texts in a single call when possible. `RubyLLM.embed(["text1", "text2"])` is much faster than calling `RubyLLM.embed` twice.
*   **Caching/Persistence:** Embeddings are generally static for a given text and model. Store generated embeddings in your database or cache instead of regenerating them frequently.
*   **Dimensionality:** Different models produce vectors of different lengths (dimensions). Ensure your storage and similarity calculation methods handle the correct dimensionality (e.g., `{{ site.models.embedding_small }}` uses 1536 dimensions, `{{ site.models.embedding_large }}` uses 3072).
*   **Normalization:** See [Normalization](#normalization) above. OpenAI and `gemini-embedding-2` vectors arrive normalized; `gemini-embedding-001` vectors do not when you reduce their width, and normalizing them is your responsibility.

## Rails Integration Example

In a Rails application using PostgreSQL with the `pgvector` extension, you might store and search embeddings like this:

```ruby
# Migration:
# add_column :documents, :embedding, :vector, limit: 1536 # Match your model's dimensions

# app/models/document.rb
class Document < ApplicationRecord
  has_neighbors :embedding # From the neighbor gem for pgvector

  # Automatically generate embedding before saving if content changed
  before_save :generate_embedding, if: :content_changed?

  # Scope for nearest neighbor search
  scope :search_by_similarity, ->(query_text, limit: 5) {
    query_embedding = RubyLLM.embed(query_text).vectors
    nearest_neighbors(:embedding, query_embedding, distance: :cosine).limit(limit)
  }

  private

  def generate_embedding
    return if content.blank?
    puts "Generating embedding for Document #{id}..."
    begin
      embedding_result = RubyLLM.embed(content) # Uses default embedding model
      self.embedding = embedding_result.vectors
    rescue RubyLLM::Error => e
      errors.add(:base, "Failed to generate embedding: #{e.message}")
      # Prevent saving if embedding fails (optional, depending on requirements)
      throw :abort
    end
  end
end

# Usage in controller or console:
# Document.create(title: "Intro to Ruby", content: "Ruby is a dynamic language...")
# results = Document.search_by_similarity("What is Ruby?")
# results.each { |doc| puts "- #{doc.title}" }
```

> This Rails example assumes you have the `pgvector` extension enabled in PostgreSQL and are using a gem like `neighbor` for ActiveRecord integration.
{: .note }

## Next Steps

Now that you understand embeddings, you might want to explore:

*   [Chatting with AI Models]({% link _core_features/chat.md %}) for interactive conversations.
*   [Using Tools]({% link _core_features/tools.md %}) to extend AI capabilities.
*   [Error Handling]({% link _advanced/error-handling.md %}) for building robust applications.
