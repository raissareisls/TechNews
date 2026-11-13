'use strict';

const api = 'https://dev.to/api/articles';
const pageSize = 36;
const storageKey = 'technews.saved.v1';
const byId = id => document.getElementById(id);
const list = byId('articles');
const status = byId('status');
const more = byId('load-more');
const reader = byId('reader');
const feed = new Map();
const pending = new Set();
let favorites = readFavorites();
let view = 'feed';
let page = 1;
let loading = false;
let hasMore = true;
let feedError = '';
let readerRequest;

function readFavorites() {
  try {
    const values = JSON.parse(localStorage.getItem(storageKey) || '[]');
    return new Map(values.map(article => [article.id, article]));
  } catch {
    return new Map();
  }
}

function node(tag, className, text) {
  const result = document.createElement(tag);
  if (className) result.className = className;
  if (text) result.textContent = text;
  return result;
}

function httpsURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' ? url.href : '';
  } catch {
    return '';
  }
}

async function request(url, signal) {
  const response = await fetch(url, {
    headers: { Accept: 'application/vnd.forem.api-v1+json' },
    signal
  });
  if (!response.ok) throw new Error('HTTP ' + response.status);
  return response.json();
}

function placeholder() {
  const cover = node('div', 'cover cover-placeholder', '‹/›');
  cover.setAttribute('aria-hidden', 'true');
  return cover;
}

function story(article, featured) {
  const item = node('article', featured ? 'story feature' : 'story');
  const imageURL = httpsURL(article.cover_image) || httpsURL(article.social_image);
  if (imageURL && view === 'feed') {
    const image = node('img', 'cover');
    image.alt = '';
    image.loading = featured ? 'eager' : 'lazy';
    image.decoding = 'async';
    image.addEventListener('error', () => image.replaceWith(placeholder()), { once: true });
    image.src = imageURL;
    item.append(image);
  } else if (view === 'feed') {
    item.append(placeholder());
  }
  const copy = node('div', 'copy');
  const tag = Array.isArray(article.tag_list) ? article.tag_list[0] : '';
  if (tag) copy.append(node('p', 'topic', '#' + tag));
  const title = node('h2');
  const open = node('button', '', article.title);
  open.type = 'button';
  open.addEventListener('click', () => openReader(article));
  title.append(open);
  const metadata = [article.user?.name, article.reading_time_minutes && article.reading_time_minutes + ' min']
    .filter(Boolean).join(' · ');
  copy.append(title, node('p', 'meta', metadata));
  if (article.description) copy.append(node('p', '', article.description));

  const saved = favorites.has(article.id);
  const busy = pending.has(article.id);
  const save = node('button', 'pill save', busy ? 'Salvando…' : saved ? 'Remover dos salvos' : 'Favoritar');
  save.type = 'button';
  save.disabled = busy;
  save.dataset.article = article.id;
  save.setAttribute('aria-pressed', String(saved));
  save.setAttribute('aria-label', save.textContent + ': ' + article.title);
  save.addEventListener('click', () => toggleFavorite(article, save));
  copy.append(save);
  item.append(copy);
  return item;
}

function render(message = '') {
  const isFeed = view === 'feed';
  const articles = isFeed ? [...feed.values()] : [...favorites.values()].reverse();
  const activeId = document.activeElement?.dataset.article;
  const oldMoreFocus = document.activeElement === more;
  byId('saved-count').textContent = favorites.size ? String(favorites.size) : '';
  list.replaceChildren(...articles.map((article, index) => story(article, isFeed && index === 0)));
  if (activeId) list.querySelector('[data-article="' + activeId + '"]:not(:disabled)')?.focus({ preventScroll: true });
  status.textContent = message || (isFeed
    ? (loading ? 'Buscando artigos no DEV Community…' : feedError || (!articles.length ? 'Nenhum artigo disponível.' : ''))
    : (!articles.length ? 'Nenhum artigo salvo. Favorite um artigo no feed para ler depois.' : ''));
  more.hidden = !isFeed || !hasMore || (!feed.size && !feedError);
  more.disabled = loading;
  more.textContent = feedError ? 'Tentar novamente' : 'Carregar mais artigos';
  if (oldMoreFocus && more.hidden) status.scrollIntoView({ block: 'nearest' });
}

async function loadPage() {
  if (loading || !hasMore) return;
  loading = true;
  feedError = '';
  render();
  try {
    const articles = await request(api + '?page=' + page + '&per_page=' + pageSize, AbortSignal.timeout(15000));
    if (!Array.isArray(articles)) throw new Error('Resposta inválida');
    for (const article of articles) {
      if (Number.isInteger(article.id) && typeof article.title === 'string') feed.set(article.id, article);
    }
    page += 1;
    hasMore = articles.length === pageSize;
  } catch {
    feedError = 'Não foi possível carregar os artigos. Verifique a conexão e tente novamente.';
  } finally {
    loading = false;
    render();
  }
}

async function toggleFavorite(article, button) {
  if (pending.has(article.id)) return;
  const removing = favorites.has(article.id);
  let message = '';
  pending.add(article.id);
  button.disabled = true;
  button.textContent = removing ? 'Removendo…' : 'Salvando…';
  try {
    const complete = removing ? null : await request(api + '/' + article.id, AbortSignal.timeout(15000));
    if (!removing && (typeof complete.body_markdown !== 'string' || !complete.body_markdown.trim())) {
      throw new Error('Texto indisponível');
    }
    const next = new Map(favorites);
    if (removing) next.delete(article.id);
    else next.set(article.id, { ...article, body_markdown: complete.body_markdown });
    localStorage.setItem(storageKey, JSON.stringify([...next.values()]));
    favorites = next;
    message = removing ? 'Artigo removido dos salvos.' : 'Artigo salvo neste navegador.';
  } catch {
    message = removing ? 'Não foi possível remover o artigo.' : 'Não foi possível salvar o texto. Tente novamente.';
  } finally {
    pending.delete(article.id);
    const restoreFocus = document.activeElement === button || document.activeElement === document.body;
    render(message);
    if (restoreFocus && !reader.open) {
      (list.querySelector('[data-article="' + article.id + '"]') || document.querySelector('[data-view="' + view + '"]'))
        ?.focus({ preventScroll: true });
    }
  }
}

async function openReader(article) {
  byId('reader-title').textContent = article.title;
  byId('reader-author').textContent = article.user?.name || '';
  byId('reader-body').textContent = '';
  byId('reader-status').textContent = '';
  const link = byId('reader-link');
  const url = httpsURL(article.url);
  link.hidden = !url;
  if (url) link.href = url;
  reader.showModal();
  reader.scrollTop = 0;
  const cached = favorites.get(article.id)?.body_markdown;
  if (cached) {
    byId('reader-body').textContent = cached;
    return;
  }
  const controller = new AbortController();
  readerRequest = controller;
  byId('reader-status').textContent = 'Carregando texto…';
  try {
    const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(15000)]);
    const complete = await request(api + '/' + article.id, signal);
    if (!reader.open || readerRequest !== controller) return;
    byId('reader-body').textContent = complete.body_markdown || article.description || '';
    byId('reader-status').textContent = '';
  } catch {
    if (!reader.open || readerRequest !== controller) return;
    byId('reader-body').textContent = article.description || '';
    byId('reader-status').textContent = 'Não foi possível carregar o texto completo.';
  }
}

reader.addEventListener('close', () => {
  readerRequest?.abort();
  readerRequest = undefined;
});

for (const button of document.querySelectorAll('[data-view]')) {
  button.addEventListener('click', () => {
    view = button.dataset.view;
    for (const tab of document.querySelectorAll('[data-view]')) {
      tab.setAttribute('aria-pressed', String(tab === button));
    }
    byId('heading').textContent = view === 'feed' ? 'Tecnologia em pauta.' : 'Artigos salvos.';
    byId('subtitle').textContent = view === 'feed'
      ? 'Artigos de programação escritos pela comunidade.'
      : 'Abra os textos guardados neste navegador.';
    render();
  });
}
more.addEventListener('click', loadPage);
loadPage();
