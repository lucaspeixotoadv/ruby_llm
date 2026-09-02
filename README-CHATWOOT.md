# Fork do ruby_llm — branch `develop`

Esta branch parte de `ruby_llm 1.16.0` (tag upstream `1.16.0`, commit `2cf34b9`)
e carrega correções pontuais que precisamos e que o upstream só resolveu na
linha 2.0.

## Por que ela existe

O upstream começou a reescrita da 2.0 um dia depois de publicar a 1.16.0.
Todas as correções que precisamos vivem sobre a refatoração de *protocols*,
que é incompatível com `ai-agents 0.12.0` (`ruby_llm ~> 1.14`), do qual o
Captain v2 depende. Ficamos na 1.16 e trouxemos só o que é necessário.

## Versões

O Chatwoot consome **sempre uma tag imutável**, nunca a branch.

| Tag | O que é |
|---|---|
| `1.16.0` | referência ao upstream puro que serve de base (commit `2cf34b9`) |
| `1.16.1` | primeiras correções do fork: Gemini inline images, temperatura GPT-5, `systemInstruction` |
| `1.16.2` | semântica zero-vs-desconhecido em pricing/usage, pricing temporal, registry Gemini atualizado |

`RubyLLM::VERSION` continua **`1.16.0`** de propósito: qualquer bump quebra o
`~> 1.14` do `ai-agents`. O versionamento do fork vive só nas tags.

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

Assim que **as duas** condições valerem:

1. `ruby_llm 2.0` tiver release ou RC estável publicado no RubyGems;
2. houver caminho compatível para o `ai-agents`, ou o Captain deixar de
   depender dele.

Migrar é apagar o fork e voltar para a gem publicada — checando antes se as
correções de 1.16.2 chegaram ao upstream, porque várias delas não são
cherry-picks de commits existentes.
