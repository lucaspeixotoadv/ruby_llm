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

`RubyLLM::VERSION` continua **`1.16.0`** porque marca a base upstream de onde
o fork parte; a identidade de cada release do fork vive na tag. Não há mais
nenhuma restrição externa de versão a respeitar.

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
correções de 1.16.2 e 1.16.3 chegaram ao upstream, porque várias delas não são
cherry-picks de commits existentes.
