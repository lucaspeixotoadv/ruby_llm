# Fork temporário do ruby_llm — branch `chatwoot-1.16`

Esta branch é **exatamente** `ruby_llm 1.16.0` (tag upstream `1.16.0`,
commit `2cf34b9`) **mais três correções pontuais**. Ela não é uma linha de
desenvolvimento independente e não deve receber trabalho novo.

## Por que ela existe

O upstream começou a reescrita da 2.0 um dia depois de publicar a 1.16.0.
Todas as correções que precisamos vivem sobre a refatoração de *protocols*,
que é incompatível com `ai-agents 0.12.0` (`ruby_llm ~> 1.14`), do qual o
Captain v2 depende. Ficamos na 1.16 e trouxemos só o que é necessário.

## O que tem aqui

| Commit | Origem | O que faz |
|---|---|---|
| `addf884` | cherry-pick `0f0ba2d1` | Gemini deixava cair imagens inline em respostas que misturam texto e imagem |
| `9b1fbfd` | cherry-pick `d7040333` | temperatura só é forçada a 1.0 nos modelos GPT-5 que de fato a recusam |
| `9b98e97` | patch manual | mensagens `:system` vão em `systemInstruction`, e não como turno `user` em `contents` |

O terceiro é uma reimplementação, não um cherry-pick: o commit upstream
correspondente (`3c9f429`) atravessa a refatoração de protocols e conflita
em ~20 arquivos.

## Versionamento

`RubyLLM::VERSION` continua **`1.16.0`**, de propósito: qualquer bump quebra
o `~> 1.14` do `ai-agents`. O fork se identifica pela tag
(`v1.16.0-chatwoot.1`), e o Chatwoot consome a tag — nunca a branch.

## Quando abandonar este fork

Assim que **as duas** condições valerem:

1. `ruby_llm 2.0` tiver release ou RC estável publicado no RubyGems;
2. houver caminho compatível para o `ai-agents`, ou o Captain deixar de
   depender dele.

Na 2.0 as três correções são redundantes: a `systemInstruction` é nativa,
e as outras duas já estão no `main`. Migrar é apagar o fork e voltar para
a gem publicada.
