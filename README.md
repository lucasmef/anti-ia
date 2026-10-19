# Sinal IA

**Confira declarações de IA nos metadados de imagens e vídeos, direto no Mac.**

Aplicativo local para macOS. Arraste vídeos ou imagens para a janela ou para o ícone do app, ou use **Escolher arquivos**. Aceita vídeos MOV, MP4 e M4V e imagens JPG/JPEG, PNG, WebP, HEIC/HEIF, AVIF e TIFF, além de XMP global de PSD/PSB; processa lotes mistos em sequência. Abra `Sinal IA.app` com duplo clique. É possível mantê-lo no Dock ou copiar para Aplicativos.

Não precisa de servidor, conta, API, IA, Python ou conexão à internet para executar. Arquivos no iCloud precisam estar disponíveis localmente; o macOS pode baixar arquivos que ainda não estejam no disco.

## Resultados

- **IA declarada nos metadados:** encontrou uma declaração IPTC reconhecida em XMP ou nos objetos CBOR/JSON do histórico C2PA, inclusive ingredientes. Pode corresponder a uma imagem usada na edição, não ao vídeo inteiro.
- **Credenciais presentes · revisar:** encontrou C2PA, sem declaração de IA reconhecida. Credenciais de procedência também existem em conteúdo de câmera.
- **Nenhum sinal nos metadados lidos:** os blocos examinados não contêm declarações reconhecidas. Não garante ausência de IA ou de rótulo no Instagram.
- **Verificação inconclusiva:** formato não suportado, erro de leitura, limite de segurança ou metadados que não puderam ser interpretados.

Lê a estrutura do arquivo por offsets e pula os dados de áudio/vídeo. Não faz upload, não modifica arquivos, não usa um modelo de detecção visual e não consulta o Instagram. O botão **Salvar relatório** exporta evidências e limitações em JSON.

## Abrir no Mac

Compile o projeto seguindo as instruções abaixo e abra `Sinal IA.app`. Você pode copiar o aplicativo para `~/Applications` e mantê-lo no Dock em **Opções → Manter no Dock**.

## Limitações da versão 1.2

É um scanner de declarações de metadados, não um validador criptográfico C2PA. Não verifica assinaturas, confiança de certificados, vínculo entre assinatura e mídia, manifestos remotos, marcas invisíveis ou sinais incorporados aos frames/áudio. Lê os manifestos locais e seu histórico sem resolver qual ação se refere ao vídeo final ou a um ingrediente. Uma declaração pode estar desatualizada, adulterada ou se referir somente a um elemento da composição.

A leitura suporta a estrutura ISO BMFF comum, C2PA UUID com versão 0 e propósitos manifest/original/update, JUMBF de tamanho de 32 bits, CBOR de tamanho definido ou indefinido e XMP. Metadados proprietários e estruturas não reconhecidas podem ficar fora da cobertura. Limites: 64 MiB lidos, 32 MiB por bloco e profundidade limitada; erros reconhecidos são apresentados como inconclusivos. Vídeos de vários GB são suportados sem carregar o conteúdo inteiro.

Imagens: lê C2PA em JPEG APP11 (inclusive fragmentado), PNG caBX, WebP C2PA, TIFF tag 52545 e UUID em HEIC/HEIF/AVIF. Lê XMP em JPEG APP1 (inclusive estendido), PNG iTXt/zTXt/tEXt (inclusive comprimido), WebP e TIFF tag 700. Em HEIC/HEIF/AVIF, o macOS extrai XMP via ImageIO; depende dos formatos reconhecidos pelo sistema. Nesses casos `additionalSystemReads` indica que `bytesRead` não inclui leituras internas do macOS. Não descomprime pixels. Não é um validador completo da integridade da imagem. BigTIFF, GIF, RAW e metadados proprietários não têm suporte nesta versão.

PSD/PSB: lê o recurso XMP global (1060). Se houver declaração explícita reconhecida, mostra alerta. Caso contrário, classifica como inconclusivo, pois não inspeciona camadas, objetos inteligentes ou estruturas proprietárias. A extensão é conferida pelo cabeçalho para JPEG, PNG, WebP, TIFF e PSD, sem modificar o arquivo.

As imagens em `tests/fixtures` foram geradas para testes com o ImageIO do macOS, com e sem declarações IPTC. Nenhuma imagem pessoal está incluída. `tests/make_images.swift` permite regenerá-las.

Os nomes de softwares são informativos: usar Premiere ou Photoshop, por si só, não dispara alerta. A ordem dos softwares exibida é alfabética, não uma linha do tempo.

## Desenvolvimento

Requer Xcode Command Line Tools somente para compilar:

```sh
./build.sh
python3 -m unittest discover -s tests -v
"./Sinal IA.app/Contents/MacOS/SinalIA" --scan /caminho/video.mov
```

O build gera um app nativo para a arquitetura deste Mac, assinado localmente (ad hoc), não notarizado para distribuição pública. Fontes em `Sources/`.

## Referências

- [Meta: abordagem para rótulos de IA](https://about.fb.com/news/2024/04/metas-approach-to-labeling-ai-generated-content-and-manipulated-media/).
- [C2PA: credenciais e formato BMFF](https://spec.c2pa.org/specifications/specifications/2.2/specs/ContentCredentials.html).
- [IPTC: vocabulário Digital Source Type](https://cv.iptc.org/newscodes/digitalsourcetype/).

O rótulo depende da plataforma; este aplicativo identifica sinais locais e não promete prever sua decisão.

## Lotes grandes

`batch_scan.py scan PASTA PASTA_DO_RELATORIO` usa o mesmo executável em lotes, gera inventário, evidências e um plano. `batch_scan.py move PASTA PASTA_DO_RELATORIO` aplica somente esse plano: verifica identidade, tamanho e data de modificação de cada arquivo, impede sobrescritas e registra cada movimento. O destino é `alerta de ia` dentro da pasta original. O script exige Python 3; o aplicativo gráfico continua independente de Python. O modo move muda caminhos: projetos que referenciam os arquivos podem precisar relocalizá-los.

## Limpeza solicitada de PNG/JPEG

`clean_metadata.py` é um utilitário separado da interface de verificação. A limpeza não é executada pelo app ao arrastar um arquivo. O modo `prepare` cria novas versões numa pasta temporária, remove somente credenciais C2PA de PNG e declarações IPTC de IA no XMP de JPEG e verifica todas as saídas com o scanner. Outros formatos de metadados não são limpos automaticamente.

PNG: todos os bytes fora dos blocos de credenciais são preservados, incluindo pixels comprimidos, perfil de cor, transparência e animação. JPEG: dados comprimidos, tabelas, EXIF e perfis de cor são preservados; somente o pacote XMP é reescrito quando contém os campos de IA reconhecidos. Sem recompressão. Etiquetas do Finder, FinderInfo, demais atributos estendidos do usuário, permissões e datas são copiados e conferidos. O atributo interno de compressão `com.apple.decmpfs` não é transplantado para dados diferentes.

O modo `commit` exige `--delete-originals`. Verifica os hashes e metadados novamente, troca cada par de arquivos atomicamente, mantém os originais na pasta temporária até concluir a validação de todos os pares e só então os apaga. A exclusão dos originais não é reversível pelo relatório; os relatórios guardam hashes e registros de operação, não cópias das credenciais removidas. Se uma execução for interrompida, examine o diário e a pasta temporária antes de continuar.

## Privacidade do repositório

Relatórios gerados podem conter nomes, caminhos e metadados dos arquivos analisados. A pasta `reports/`, os aplicativos compilados, caches de build e arquivos de ambiente são ignorados pelo Git. Antes de compartilhar um relatório, revise seu conteúdo. Os fixtures incluídos são imagens sintéticas de teste.
