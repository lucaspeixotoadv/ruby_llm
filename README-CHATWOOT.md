# Fork do ruby_llm — branch `develop`

Esta branch parte de `ruby_llm 1.16.0` (tag upstream `1.16.0`, commit `2cf34b9`)
e carrega correções pontuais que precisamos e que o upstream só resolveu na
linha 2.0.

## Por que ela existe

O upstream começou a reescrita da 2.0 um dia depois de publicar a 1.16.0.
Todas as correções que precisamos vivem sobre a refatoração de *protocols*,
que ainda não tem release estável. Ficamos na 1.16 e trouxemos só o que é
necessário.

## Versões

O Chatwoot consome **sempre uma tag imutável**, nunca a branch.

| Tag | O que é |
|---|---|
| `1.16.0` | referência ao upstream puro que serve de base (commit `2cf34b9`) |
| `1.16.1` | primeiras correções do fork: Gemini inline images, temperatura GPT-5, `systemInstruction` |
| `1.16.2` | semântica zero-vs-desconhecido em pricing/usage, pricing temporal, registry Gemini atualizado |
| `1.16.3` | `embedding_dimensions` como campo próprio; `metadata.status` verificado ponta a ponta |
| `1.16.4` | temperatura e reasoning consultados no registry, sem regex por id de modelo |
| `1.16.5` | embeddings declaram sua finalidade: `taskType` e `title` no Gemini, com capabilities por modelo |
| `1.16.6` | arquivos em resultado de tool chegam ao modelo como arquivo, em todo provider; registry atualizado |
| `1.16.7` | cache explícito do Gemini (`cachedContents`): criação e requisição que o referencia |
| `1.16.8` | chamada de ferramenta de outro provider aceita pelo Gemini 3 (assinatura documentada) |
| `1.16.9` | Anthropic com os modelos Claude 5.x: raciocínio devolvido íntegro, temperatura, recusa, `disabled`, `/v1/models`; registry atualizado |

`RubyLLM::VERSION` acompanha a tag: a partir da `1.16.3` a constante é a
mesma coisa que a tag, e não mais a versão da base upstream. Ela ficou presa
em `1.16.0` até a `1.16.2` por causa de uma restrição externa que não existe
mais.

Fluxo: trabalha-se em `develop`, valida-se, publica-se uma tag nova, e o
`Gemfile` do Chatwoot passa a apontar para ela.

### 1.16.1 — correções herdadas

| Commit | Origem | O que faz |
|---|---|---|
| `addf884` | cherry-pick `0f0ba2d1` | Gemini deixava cair imagens inline em respostas que misturam texto e imagem |
| `9b1fbfd` | cherry-pick `d7040333` | temperatura só é forçada a 1.0 nos modelos GPT-5 que de fato a recusam |
| `9b98e97` | patch manual | mensagens `:system` vão em `systemInstruction`, e não como turno `user` em `contents` |

O terceiro é uma reimplementação, não um cherry-pick: o commit upstream
correspondente (`3c9f429`) atravessa a refatoração de protocols e conflita
em ~20 arquivos.

### 1.16.2 — zero versus desconhecido, e pricing temporal

O tema é um só: **ausência de informação não pode virar `0`.** A lib passa a
distinguir três estados em todo caminho de pricing e usage:

- **conhecido** — um número com que dá para calcular;
- **efetivamente zero** — `0.0`, um preço que o provider realmente cobra;
- **desconhecido** — `nil`, a ausência de informação.

Consumidores como o Chatwoot dependem dessa distinção para decidir entre
persistir um custo, persistir zero, ou registrar que não há custo apurável.

**Pricing**

- `Gemini::Capabilities.pricing_for` não devolve mais o fallback inventado de
  `$0.075/$0.30` para famílias desconhecidas — devolve ausência de pricing.
- `OpenAI::Capabilities` tinha o mesmo defeito (`$0.50/$1.50` para a família
  `other`) e foi corrigido junto.
- `Model::PricingTier` deixou de descartar `0.0`. Um preço zero é um preço
  conhecido; só `nil` é descartado.
- `gemini-embedding-001` não é mais classificado como gratuito: só os
  embedders legados (`text-embedding-004`, `embedding-001`) de fato são.

**Usage**

- `Embedding#input_tokens` agora é `nil` quando o provider não reportou usage,
  e ganhou `#input_tokens?` e `#cost`.
- Gemini embeddings passam a ler o `usageMetadata.promptTokenCount` que a API
  realmente devolve (`BatchEmbedContentsResponse`) em vez de gravar `0`.
- Vertex AI embeddings passam a somar `embeddings.statistics.token_count`.
- OpenAI e Mistral embeddings não convertem mais usage ausente em `0`.
- `Gemini::Chat` e `Gemini::Transcription` deixam output tokens desconhecidos
  como `nil` quando a resposta não traz contagem, alinhando com o streaming,
  que já fazia certo.
- `OpenAI::Chat` não afirma mais `0` cache writes quando a resposta é omissa.

**Pricing temporal**

`Model::PricingSchedule` permite que um tier carregue uma lista datada de
preços. A API existente não muda — `model.pricing.text_tokens.input` devolve o
preço vigente agora — e ganha `pricing.at(time)` e `Cost.new(..., at:)` para
precificar uma chamada no momento em que ela aconteceu.

Existe porque Google anunciou preço promocional para 3.6/3.7 Flash com data de
virada conhecida. Gravar só o preço de hoje deixaria o registry errado a partir
de 01/01/2027; gravar só o de amanhã o deixa errado até lá.

**Registry**

Atualizado via o caminho oficial (`Models.refresh!` com `GEMINI_API_KEY`), não
por edição manual. Resultado: +13 modelos Gemini (incluindo `gemini-3.6-flash`
e `gemini-3.7-flash`), zero remoções, e 29 entradas corrigidas — a maioria
perdendo o pricing inventado ou ganhando `reasoning`/`caching`.

Três proteções foram adicionadas ao merge para que um refresh não desfaça o
trabalho nem apague informação boa:

1. um schedule vindo do provider vence um preço plano do models.dev — o
   models.dev não tem como expressar mudança de preço com data;
2. uma entrada models.dev **sem** `metadata.cost` nunca precificou nada, então
   o preço que estiver nela veio de um refresh anterior do próprio provider e
   não pode ser relido como se fosse fato do models.dev;
3. um modelo que o refresh não viu é **preservado**, não deletado. O
   `ListModels` do Gemini não retorna os modelos imagen e veo, e o que uma
   chave enxerga varia — ausência de uma listagem não prova aposentadoria, e
   apagar quebra chamadas que ainda funcionam. O pricing do modelo preservado
   é re-derivado do provider, para que um preço inventado antigo não sobreviva
   só por o modelo estar fora da listagem.

### 1.16.3 — dimensão de embedding como campo próprio, e `metadata.status`

**O problema**

O `models.dev` não tem campo para largura de vetor. Nas entradas de embedding
ele coloca um número em `limit.output` — que o RubyLLM mapeia para
`max_output_tokens`, o limite de *tokens gerados*. Às vezes esse número
coincide com a dimensão (`text-embedding-3-large`: 3072), às vezes não é nada
(`gemini-embedding-001`: **1**). Quem lê o limite de tokens como dimensão
acerta num modelo e cria um vetor de 1 dimensão no seguinte.

**A correção**

`embedding_dimensions` passa a ser campo de primeira classe do `Model::Info`,
com objeto de valor próprio (`RubyLLM::Model::EmbeddingDimensions`), entrada no
schema do registry, coluna opcional no registry ActiveRecord e presença no
`to_h`/JSON. `limit.output` continua significando exatamente o que sempre
significou — e nunca mais é lido como dimensão.

Formato:

```json
"embedding_dimensions": {
  "default": 3072,
  "configurable": true,
  "supported": [768, 1536, 3072],
  "min": 128,
  "max": 3072
}
```

- `default` — a largura devolvida quando nada é pedido;
- `configurable` — se o modelo aceita parâmetro de dimensão (Matryoshka);
- `supported` — a lista discreta que o provider documenta, quando existe;
- `min`/`max` — a faixa contínua, quando o provider documenta uma.

Modelo de largura fixa carrega só `{ "default": n, "configurable": false }`.
Nada é inferido além do que o provider afirma: um modelo configurável sem faixa
publicada (`codestral-embed`) fica sem `min`/`max` em vez de ganhar limites
inventados, e uma largura desconhecida continua `nil`, não `0`.

`gemini-embedding-001` fica representado como acima: padrão 3072, faixa
128–3072, e 768/1536/3072 como as dimensões recomendadas pelo Google — tudo
convivendo com `max_output_tokens: 1`, que continua sendo o que o `models.dev`
diz sobre tokens.

API no `Model::Info`:

| Método | Devolve |
|---|---|
| `embedding_dimensions` | o objeto de valor, ou `nil` |
| `default_embedding_dimensions` | `Integer` ou `nil` |
| `configurable_embedding_dimensions?` | `true`/`false` |
| `supports_embedding_dimensions?(n)` | se `n` é uma largura válida |

A largura vem das capabilities do provider (OpenAI, Gemini/Vertex, Mistral,
Bedrock), não do `models.dev`. `Gemini::Capabilities.max_tokens_for` deixou de
devolver `768` para os embedders: aquilo era a dimensão usando o nome errado.

**Normalização de modalidades**

Modelos de embedding que só existem na listagem do provider (Azure e Gemini não
reportam modalidades; Mistral diz que `mistral-embed` produz `text`) passavam
pelo merge sem a normalização que o caminho do `models.dev` já fazia, e saíam
do registry tipados como `chat` — fora de `RubyLLM.models.embedding_models`. A
mesma normalização passou a valer para eles: 14 entradas corrigidas.

**`metadata.status`**

Verificado ponta a ponta (`models.dev` → parsing → `Model::Info` → merge com
provider → `to_h` → JSON → refresh → ActiveRecord) e coberto por testes. O
campo já era preservado; nenhuma camada nova foi criada. O que se acrescentou
foram leitores tipados — `Model::Info#status` e `#deprecated?` — que aceitam a
chave como símbolo ou string, já que uma coluna `jsonb` devolve string.

Regras que continuam valendo, agora com teste que as fixa:

- disponibilidade **não** se decide por nome de modelo;
- não existe blacklist local (`gemini-2.5-*` inclusive);
- se o `models.dev` não marca um modelo como `deprecated`, o RubyLLM devolve
  `nil` — corrigir o dado é responsabilidade da fonte, não do fork.

**Consumo no Chatwoot**

Passa a ser possível ler `model.default_embedding_dimensions` em vez de usar
`limit.output`/`max_output_tokens` como fallback de dimensão, e
`model.status` / `model.deprecated?` para decidir se um modelo entra em novas
seleções. Nenhuma regra de seleção ou de UI vive aqui.

Registries ActiveRecord ganham a coluna `embedding_dimensions` (`jsonb`/`json`)
via `bin/rails generate ruby_llm:upgrade_to_v1_16_3`. Sem a migração o resto do
round-trip continua funcionando; só a largura não é persistida.

### 1.16.4 — temperatura e reasoning saem do registry, não do nome do modelo

**O problema**

Duas capabilities que o registry já descrevia estavam sendo re-derivadas fora
dele.

A temperatura era decidida por regex sobre `model.id`, em
`OpenAI::Temperature`: `/^o\d/`, `/^gpt-5(\.\d+)?(-\d{4})?$/` e
`/^gpt-5(\.\d+)?-pro/`. `gpt-5-mini` e `gpt-5-nano` não casam com nenhuma
delas e recebiam `temperature`, que a API recusa — o `models.dev` afirma
`temperature: false` para os dois. E os ids que casavam tinham a temperatura
**reescrita para 1.0**, um valor que quem chamou nunca pediu, trocado em
silêncio.

O reasoning tinha o dado (`capabilities` inclui `reasoning`;
`metadata.reasoning_options` quando a fonte enumera) e nenhuma API para
perguntar por ele. `reasoning_options` existe em 30 modelos — anthropic 17,
gemini 8, mistral 3, deepseek 2 — e em **nenhum** da OpenAI: ler a ausência da
enumeração como ausência de suporte silenciaria a linha inteira.

E `with_thinking(budget:)` na OpenAI era no-op silencioso: aceito pela API
pública da lib e descartado antes do payload.

**A correção**

`Model::Info` ganha as perguntas, e a normalização passa a consultá-las:

```ruby
model.supports_temperature?          # true | false | nil
model.rejects_temperature?           # só true quando o registry afirma false
model.supports_reasoning?            # capability, independente das options
model.reasoning_efforts              # ["low", "medium", "high"] ou []
model.supports_reasoning_effort?(:medium)
model.supports_reasoning_budget?(2048)
model.minimum_reasoning_budget
model.maximum_reasoning_budget
```

Três estados, não dois — mesma semântica de `metadata.status`. `true` e
`false` são afirmações da fonte; `nil` é a fonte não dizendo nada. Um modelo
sem `reasoning_options` não é um modelo sem reasoning: é um modelo cujas
opções a fonte nunca enumerou.

Modelo que recusa temperatura tem o parâmetro **omitido**, não substituído por
1.0 — o default do próprio modelo prevalece, que é o que a API faz de todo
jeito.

`with_thinking(budget:)` na OpenAI passa a levantar `ArgumentError`. Isso é
propriedade do *endpoint*, não do modelo: chat completions dirige o raciocínio
por `reasoning_effort` e não tem campo para budget, então nenhuma consulta ao
registry decide — vale igual para Azure, DeepSeek, xAI, Perplexity, Ollama,
GPUStack e Mistral, que falam o mesmo dialeto. Mesma convenção que o Anthropic
já usava para um budget que o modelo não aceita.

Sem lista local de modelos, sem allowlist, sem exceção por família.

**Payloads**

| Chamada | Antes | Depois |
|---|---|---|
| `gpt-5-mini` + `with_temperature(0.2)` | `temperature: 0.2` (400) | omitida |
| `gpt-5` + `with_temperature(0.2)` | `temperature: 1.0` | omitida |
| `gpt-4o` + `with_temperature(0.2)` | `0.2` | `0.2` |
| `gpt-5.4` + `with_thinking(effort:)` | `reasoning_effort` | `reasoning_effort` |
| `gpt-5.4` + `with_thinking(budget:)` | descartado | `ArgumentError` |
| Gemini | `thinkingLevel` / `thinkingBudget` | inalterado |

**Ressalva**

Ids que chegam ao registry só pela listagem do provider — snapshots datados
(`o1-2024-12-17`, `gpt-5-2025-08-07`) e previews (`gpt-4o-search-preview`,
`gpt-5-search-api`) — não têm `metadata.temperature`. Como `nil` não é `false`,
esses passam a receber a temperatura configurada, onde a regex acertava dois
deles por acidente. É um erro visível da API em vez de um valor trocado em
silêncio, e o alcance é pequeno: `Chat#temperature` é `nil` por padrão, então
só atinge quem chama `with_temperature` explicitamente nesses ids. Corrigir o
dado é da fonte, não do fork.

**Consumo no Chatwoot**

Dá para perguntar ao modelo, antes de montar a chamada, se ele aceita
temperatura e como o raciocínio dele é dirigido, em vez de manter uma tabela
de ids do lado de cá. `nil` deve ser tratado como desconhecido, não como não.

Sem migração: nada de novo é persistido, tudo sai de `metadata`, que o
registry já carrega.

### 1.16.6 — arquivos em resultado de tool

**O problema**

Uma tool pode responder com um `RubyLLM::Content` com anexos -- a imagem que
ela buscou, o PDF que ela leu --, e o `Chat` guarda esse `Content` na mensagem
de tool. O que cada provider fazia com ele:

| Provider | Antes |
|---|---|
| Anthropic | blocos `image`/`document` dentro do `tool_result` -- correto |
| OpenAI (e os compatíveis) | partes `image_url`/`file` numa mensagem `role: tool`, que a Chat Completions só aceita com texto: requisição recusada |
| Gemini / Vertex AI | as partes dentro de `functionResponse.response.content`: o modelo recebia o base64 como string de dado, e não como imagem |
| Bedrock | `attachment.for_llm` num bloco de texto: o data URI inteiro como texto |

**A correção**

O contrato da tool não muda: ela devolve `Content` com anexos. Cada provider
entrega os arquivos pelo canal que a API tem para arquivos.

- **Anthropic** -- como já era.
- **Bedrock** -- os anexos viram os blocos `image`/`document` do Converse, que
  o `toolResult` aceita, pelo mesmo `Media.render_content` das mensagens.
- **Gemini 3** -- imagens (`png`, `jpeg`, `webp`), PDF e `text/plain` vão
  DENTRO do `functionResponse`, em `parts` com `inline_data` e `display_name`,
  e o `response` aponta para cada um por `{"$ref": display_name}`. É o recurso
  "multimodal function responses", documentado para a série Gemini 3.
- **Gemini anterior ao 3, ou tipo que o `functionResponse` não aceita** (um
  áudio) -- o arquivo vai AO LADO, como parte do mesmo turno, depois de todas
  as function responses daquele turno.
- **OpenAI e todo provider sem suporte** -- `RubyLLM::ToolResultAttachments`:
  cada resultado de tool fica com o texto dele e diz que os arquivos vêm a
  seguir, e os arquivos de toda a sequência de resultados vão numa mensagem
  `user` logo depois do último -- a API exige cada resultado colado na chamada
  que o pediu. O provider declara o que a API dele faz em
  `Provider#tool_results_carry_attachments?`; o padrão é não carregar, que é
  o caminho seguro para um provider novo.

O histórico do `Chat` não muda: a realocação acontece na lista que está sendo
renderizada, e a mensagem de tool continua guardando o `Content` que a tool
devolveu.

**Registry**

A tag também leva a atualização do `models.json`/`aliases.json` a partir do
models.dev (`cb15660`). Três specs que fixavam exemplos no dado do registry
foram atualizados para modelos que continuam no cenário que eles descrevem
(`lyria-3-pro-preview` ganhou preço, `gpt-5.4` passou a enumerar opções de
reasoning). A validação do `models.json` contra o schema voltou a rodar -- o
`json-schema` 6.2 lia o schema pelo caminho com `JSON.parse(..., quirks_mode:)`,
opção que o `json` 3.0 removeu, e agora recebe o schema já lido. Os dois
exemplos de `with_schema` com `anthropic/claude-haiku-4-5` passaram a rodar --
o registry agora declara saída estruturada no modelo -- e ganharam cassetes
gravadas contra a API.

### 1.16.5 — embeddings declaram sua finalidade

**O problema**

O `gemini-embedding-001` produz vetores **assimétricos**: o mesmo texto
embeddado como documento a ser indexado e como consulta que vai buscá-lo não
dá o mesmo vetor. Quem sabe de que lado está é a aplicação, e o
`EmbedContentRequest` tem os campos para ela dizer — `taskType` e, para
documentos, `title`. O RubyLLM mandava só `model`, `content` e
`outputDimensionality`; não havia como pedir nenhum dos dois.

A falta é silenciosa: todo RAG construído sobre a lib indexava e consultava
com vetores de propósito geral, sem erro e sem sintoma. Medido contra a API,
o que ficava de fora mexe no vetor e não é cosmético —
`cos(doc_sem_task, doc_com_RETRIEVAL_DOCUMENT) = 0.827` e
`cos(doc_task, doc_task+title) = 0.928`.

**A correção**

`RubyLLM.embed` aceita `task:` e `title:`:

```ruby
# indexação
RubyLLM.embed(texto, model: "gemini-embedding-001", dimensions: 1536,
              task: :retrieval_document, title: "Política de reembolso")

# busca
RubyLLM.embed(consulta, model: "gemini-embedding-001", dimensions: 1536,
              task: :retrieval_query)
```

`RubyLLM::Embedding::Task` é o vocabulário provider-agnostic — os oito tipos
que o EmbedContent documenta (`retrieval_document`, `retrieval_query`,
`semantic_similarity`, `classification`, `clustering`, `question_answering`,
`fact_verification`, `code_retrieval_query`) — e guarda a única regra que liga
tarefa e título: `title:` só acompanha `:retrieval_document`, como o Google
afirma ("Only applicable when TaskType is `RETRIEVAL_DOCUMENT`"). Aceita
`:retrieval_document`, `"retrieval_document"` ou `"RETRIEVAL_DOCUMENT"`.

Cada adapter traduz para o que sua API tem de fato: o Gemini manda
`taskType`/`title` em cada request do `batchEmbedContents`, o Vertex AI manda
`task_type`/`title` em cada instance do `:predict`, e a OpenAI — cujo
`/v1/embeddings` não tem o conceito, só `input`, `model`, `dimensions`,
`encoding_format` e `user` — manda exatamente o que sempre mandou.

**Capabilities por modelo**

Quais tarefas um modelo aceita é pergunta ao `Gemini::Capabilities`, ao lado
de `embedding_dimensions_for`; provider sem essa capability não aceita
nenhuma. Tarefa que o modelo escolhido não honra **levanta erro**, em vez de
ser descartada — é o que impede o uso silencioso.

Isso importa mais onde a API aceita e ignora: o `batchEmbedContents` recebe um
`taskType` para `gemini-embedding-2`, responde 200 e devolve vetor idêntico ao
que devolve sem ele (medido: cosseno 1.0). O cookbook do Google diz que nesse
modelo a instrução de tarefa vai no próprio texto. Recusar é a única forma de
quem chamou descobrir que o pedido não foi honrado. O legado `embedding-001`,
que antecede o parâmetro, também não aceita nenhuma.

**Payloads**

| Chamada | Antes | Depois |
|---|---|---|
| Gemini + `task: :retrieval_document, title:` | impossível | `taskType` + `title` no request |
| Gemini + `task: :retrieval_query` | impossível | `taskType`, sem `title` |
| Gemini sem `task:` | `model`/`content`/`outputDimensionality` | idêntico |
| OpenAI, com ou sem `dimensions:` | `model`/`input`/`dimensions` | idêntico |
| `gemini-embedding-2` + `task:` | — | `UnsupportedEmbeddingTaskError` |
| OpenAI + `task:` | — | `UnsupportedEmbeddingTaskError` |
| `title:` sem tarefa de documento | — | `InvalidEmbeddingTaskError` |

**Dimensionalidade e normalização**

`dimensions:` continua indo para o parâmetro que cada provider publica —
`dimensions` na OpenAI, `outputDimensionality` no Gemini,
`parameters.outputDimensionality` no Vertex. O que passa a estar documentado é
o que vem de volta: a OpenAI normaliza os vetores em qualquer largura,
inclusive depois de encurtar; o `gemini-embedding-001` normaliza **só** na
largura nativa. Medido: ‖v‖ = 1.0 em 3072, 0.70 em 1536, 0.58 em 768. O
`gemini-embedding-2` normaliza em toda largura.

A lib não normaliza nada por conta própria — reescalar o vetor de um provider
por baixo do pano seria trocar o significado da resposta em silêncio. Fica com
quem consome, e o guia de embeddings diz quem deve o quê.

**Consumo no Chatwoot**

Indexar com `task: :retrieval_document` (e `title:` quando o documento tiver
um), buscar com `task: :retrieval_query`, e manter os dois lados coerentes: um
índice de documento consultado com vetores de propósito geral degrada o
resultado sem acusar erro. Usando `gemini-embedding-001` em largura reduzida,
normalizar antes de gravar. Um `title:` vale para todos os textos da mesma
chamada — serve para trechos de um mesmo documento, não para documentos
diferentes.

Chamadas existentes seguem idênticas: sem `task:`, todo payload é byte a byte
o que era. Sem migração — nada de novo é persistido.

## Fontes do pricing de 3.6/3.7 Flash

Preços validados contra a página oficial de pricing do Google Cloud
(Vertex AI / Agent Platform), tier Standard, região Global:

| Janela | Input | Output | Cached input |
|---|---|---|---|
| até 2026-12-31 | $0.75 | $3.75 | $0.075 |
| a partir de 2027-01-01 | $1.50 | $7.50 | $0.15 |

Input cobre texto, imagem, vídeo e áudio na mesma linha — não há preço de áudio
separado para esses modelos. Cache *storage* explícito é cobrado por
token-hora, unidade que o registry não sabe representar, então cache write fica
desconhecido.

Ressalva: `ai.google.dev` e `docs.cloud.google.com` estavam bloqueados por
política de egress durante a coleta, então a validação usou a página do Google
Cloud. Os preços por token de Vertex e da Developer API historicamente
coincidem, mas isso não foi confirmado contra `ai.google.dev`.

## Fronteira

O RubyLLM responde fatos técnicos: o modelo existe, pertence a que provider,
que capabilities tem, que usage foi efetivamente reportado, que pricing
confiável se aplica. Nenhuma regra de produto do Chatwoot vive aqui.

## Como atualizar o registry

```sh
GEMINI_API_KEY=... OPENAI_API_KEY=... ANTHROPIC_API_KEY=... bundle exec rake models
```

Requer acesso a `models.dev` e às APIs dos providers. Sem elas o refresh é
inócuo: mantém o que já está em `models.json`.

## Quando abandonar este fork

Assim que `ruby_llm 2.0` tiver release ou RC estável publicado no RubyGems.

Migrar é apagar o fork e voltar para a gem publicada — checando antes se as
correções de 1.16.2, 1.16.3 e 1.16.4 chegaram ao upstream, porque várias delas
não são cherry-picks de commits existentes.

### 1.16.7 — cache explícito do Gemini

**O problema**

O cache implícito do Gemini é "melhor esforço". Medido no `gemini-3.8-flash`
com um prompt de sistema de ~5k tokens mais ferramentas: nada abaixo de ~6.144
tokens no total, e acima disso só acerta quando a requisição é praticamente
idêntica à anterior -- uma rodada nova de conversa, ou a volta de uma
ferramenta, quase nunca aproveitava o cache.

O cache explícito (`cachedContents`) é lido em toda requisição que o nomeia,
enquanto ele existir. A lib não tinha como criá-lo, e uma requisição com
`cachedContent` levava junto `systemInstruction` e `tools`, que o Gemini
recusa com 400 quando o cache já os contém.

**O que entra**

`Gemini::CachedContents`, incluído no provider:

- `cached_content_payload(messages, tools:, model:)` -- o que o cache guarda:
  o mesmo `systemInstruction` e as mesmas declarações de ferramenta que a
  requisição levaria, formatados pelo mesmo código. Quem usa pode derivar a
  chave do cache desse payload: prompt ou ferramenta diferente, cache
  diferente.
- `create_cached_content(payload, ttl:)` -- cria o cache por `ttl` segundos e
  devolve nome, expiração e tokens. O prazo é fixo: usar o cache não o renova.
- `Provider#finalize_payload` -- a última palavra sobre o payload, depois de
  os `params` do chamador entrarem nele. No Gemini, uma requisição com
  `cachedContent` perde `systemInstruction`, `tools` e `toolConfig`. As
  ferramentas continuam registradas no `Chat`, e as chamadas que o modelo
  fizer são executadas como sempre.

Uso: `chat.with_params(cachedContent: cache.name)`.

Validado contra a API: com cache de 4.973 tokens (prompt + uma ferramenta),
as duas idas ao modelo de uma rodada com chamada de ferramenta vieram com
`cachedContentTokenCount` 4.973. O mínimo do cache explícito no 3.8 Flash é
1.024 tokens (`Cached content is too small ... min_total_token_count=1024`).

### 1.16.8 — histórico de outro provider no Gemini 3

O Gemini 3 recusa, com 400 ("Function call is missing a thought_signature"),
uma conversa cujo histórico traz uma chamada de ferramenta sem assinatura. É o
caso de uma conversa que começou em outro provider -- a troca para um modelo
reserva no meio de uma rodada com ferramentas.

`Gemini::Tools#format_tool_call` passa a dar à primeira chamada do turno a
assinatura que o Gemini documenta para chamadas que ele não escreveu
(`skip_thought_signature_validator`), quando nenhuma delas tem assinatura e o
modelo é da série 3 em diante. A assinatura que o próprio Gemini escreveu
continua indo como veio, e os modelos anteriores não recebem nada.

Validado contra a API: histórico com chamada de ferramenta sem assinatura,
`gemini-3.8-flash`, resposta normal.

### 1.16.9 — Anthropic: modelos Claude 5.x de ponta a ponta

**O problema**

Os modelos atuais da Anthropic (Claude Opus 5.5, Sonnet 5.5, Haiku 5.5,
Fable 5.1) mudaram o contrato que o provider assumia, e cinco defeitos
apareciam assim que se usava um deles com ferramentas:

- **raciocínio devolvido errado.** Esses modelos pensam por padrão e devolvem
  o raciocínio *omitido*: blocos `thinking` com texto vazio e uma assinatura.
  Um turno de ferramentas pode trazer mais de um, entre o texto e as
  chamadas. A lib guardava só o primeiro, juntava os textos e, sem texto,
  devolvia a assinatura como `redacted_thinking` — e só quando o chamador
  tinha pedido `with_thinking`. A API recusa (400) um turno cujo raciocínio
  volta editado, fundido ou pela metade, e pede os blocos de volta em todo
  turno de ferramentas;
- **temperatura enviada a quem a recusa.** O registry afirma
  `temperature: false` para os modelos atuais, e a API responde 400 a
  qualquer temperatura; o provider da Anthropic não consultava o registry;
- **recusa lida como resposta.** `stop_reason: "refusal"` é um 200 sem
  resposta utilizável, e saía como uma mensagem vazia;
- **`effort: :none` não desligava nada.** Omitir `thinking` não desliga o
  raciocínio desses modelos: ele é o padrão. E no Opus 5.5 ele não pode ser
  desligado (`disabled` dá 400);
- **o registry ficava com a palavra do models.dev sobre raciocínio**, mesmo
  quando a própria API diz outra coisa: o models.dev não afirma que o
  raciocínio do Opus 4.7/4.8 e do Opus 5 pode ser desligado, e a API afirma.

**A correção**

- `Thinking#blocks` guarda o turno exatamente como a API o devolveu, quando
  ele traz raciocínio; o provider o devolve igual, em qualquer configuração de
  raciocínio da requisição. A API descarta sozinha o que o modelo de destino
  não lê. `text` e `signature` continuam sendo o resumo legível.
- `Providers::Temperature` (antes `OpenAI::Temperature`) vale também para a
  Anthropic: temperatura recusada pelo registry é omitida.
- `RubyLLM::RefusalError` (subclasse de `RubyLLM::Error`), com `category`
  vinda de `stop_details`, levantado na resposta síncrona e no `message_delta`
  do streaming.
- `with_thinking(effort: :none)` manda `thinking: {type: "disabled"}` quando o
  registry diz que o modelo aceita (`toggle`), e levanta `ArgumentError` quando
  não aceita — em vez de deixar o modelo pensar em silêncio.
- `Anthropic::Models` lê de `/v1/models` a janela de contexto, o teto de saída,
  as capacidades e, da árvore `capabilities`, as `reasoning_options`: os
  esforços aceitos, `toggle` quando `thinking.types.disabled` é aceito e
  `budget_tokens` quando `enabled` é. Na fusão com o models.dev, as opções de
  raciocínio que a listagem do provider afirma vencem; um modelo carregado do
  registry anterior não conta como listagem.

**Payloads**

| Chamada | Antes | Depois |
|---|---|---|
| turno de ferramentas com 2 blocos `thinking` omitidos, sem `with_thinking` | blocos descartados | turno devolvido igual |
| o mesmo, com `with_thinking(effort:)` | 1 `redacted_thinking` com a assinatura (400) | turno devolvido igual |
| `claude-opus-5-5` + `with_temperature(0.2)` | `temperature: 0.2` (400) | omitida |
| `claude-haiku-4-5` + `with_temperature(0.2)` | `0.2` | `0.2` |
| `stop_reason: "refusal"` | mensagem vazia | `RubyLLM::RefusalError` |
| `claude-haiku-5-5` + `effort: :none` | `thinking` omitido (pensa) | `thinking: {type: "disabled"}` |
| `claude-opus-5-5` + `effort: :none` | `thinking` omitido (pensa) | `ArgumentError` |

**Ressalvas**

- O streaming continua montando o raciocínio pelo acumulador genérico (texto
  e primeira assinatura), sem `Thinking#blocks`: um turno de ferramentas
  transmitido por streaming ainda não volta íntegro.
- O Haiku 5.5 tem preço por faixa de tamanho do prompt (acima de 100 mil
  tokens a entrada custa 5x). O models.dev publica as faixas (`cost.tiers`) e
  o registry guarda só a primeira: acima de 100 mil tokens o custo sai
  subestimado.
- A escrita de cache de 1 hora custa 2x a entrada, e o registry só tem o preço
  da de 5 minutos (`cache_write_input_per_million`).
- Os modelos 5.5 e o Fable 5.1 recusam `tool_choice` forçado (`any`/`tool`); o
  registry não descreve isso, e a lib manda o que o chamador pedir.

**Registry**

Atualizado pelo caminho oficial a partir do models.dev, sem chave de provider:
entram `claude-sonnet-5-5` e `claude-haiku-5-5`. As opções de raciocínio de
`/v1/models` só chegam ao `models.json` num `rake models` com
`ANTHROPIC_API_KEY`.

**Consumo no Chatwoot**

`RubyLLM::RefusalError` é falha do provider como as outras (não adianta repetir
no mesmo modelo; o modelo reserva pode assumir). O raciocínio dos turnos com
ferramentas volta íntegro sem nada do lado de cá.
