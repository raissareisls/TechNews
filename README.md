# TechNews




Leitor nativo de artigos de programação do DEV Community. O app usa SwiftUI, arquitetura MVVM e a API pública do Dev.to, sem chave de API ou dependências externas.




## Versão web


[![TechNews publicado com o feed do DEV Community](https://github.com/user-attachments/assets/0c98f574-8b2f-4de3-a9a1-e9765dcab343)](https://raissareisls.github.io/TechNews/)




[Abrir TechNews no GitHub Pages](https://raissareisls.github.io/TechNews/)




O feed tem um layout responsivo com artigo em destaque, capas e tempo de leitura. A cada página, o site busca até 36 artigos reais do DEV Community. Use **Carregar mais artigos** para continuar. A aba **Salvos** guarda o texto dos favoritos neste navegador.




O GitHub Pages publica a pasta `/docs` da branch `main`. A página usa `index.html`, `styles.css` e `app.js` nessa pasta.




A compilação da versão nativa no iOS está pendente de validação.


## Executar




**Xcode no Mac.** Abra `TechNews.xcodeproj`, escolha o esquema TechNews e execute em um simulador com iOS 16 ou posterior. Para instalar em um iPhone, selecione sua equipe em **Signing & Capabilities** e escolha o dispositivo como destino. Se a assinatura pedir um identificador exclusivo, ajuste o **Bundle Identifier**.




**Swift Playgrounds no iPad ou Mac.** Crie um playground do tipo **App** e substitua os arquivos Swift de exemplo por `TechNews.swift`. O arquivo já inclui o ponto de entrada `@main`.




## Fluxo do aplicativo




- **Feed.** A lista mostra capa, título, autor e resumo. Puxe a lista para atualizar e toque no título para abrir a leitura.
- **Salvos.** Ao favoritar, o aplicativo baixa o texto antes de gravar o artigo no dispositivo. Abra a aba Salvos para ler o texto sem conexão ou remover o favorito. Capas e imagens externas dependem de rede.
- **Leitura.** O leitor exibe o texto com formatação Markdown inline e oferece um link para o artigo original.




## Arquitetura




O código do app fica em `TechNews.swift`. O modelo `Article` mapeia o JSON da API. `DevAPI` faz as requisições com `URLSession` e `async/await`. `NewsViewModel` coordena o feed e os favoritos, e `ReaderViewModel` gerencia o carregamento do texto. As views observam esses estados. `FavoritesStore` codifica o array de artigos em JSON no `UserDefaults`.




## Teste manual




1. Abra o feed com conexão e toque em um título para ler o artigo.
2. Volte ao feed, favorite o artigo e espere o término do download.
