// C wrapper around sime_core for Swift interop.

#include "sime_api.h"
#include "sime.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

// sime::Sime holds DoubleArray by value (copy/move-deleted), so we wrap it in
// a unique_ptr to avoid assignment.
struct SimeHandle {
  std::unique_ptr<sime::Sime> sime;
};

SimeHandle *sime_create(const char *dict_path, const char *cnt_path) {
  auto *h = new SimeHandle();
  h->sime = std::make_unique<sime::Sime>(dict_path, cnt_path);
  return h;
}

void sime_destroy(SimeHandle *h) { delete h; }

bool sime_ready(const SimeHandle *h) { return h && h->sime && h->sime->Ready(); }

int sime_context_size(const SimeHandle *h) {
  return (h && h->sime) ? h->sime->ContextSize() : 0;
}

SimeTokens sime_tokenize_text(const SimeHandle *h, const char *text) {
  SimeTokens result{};
  if (!h || !h->sime || !h->sime->Ready() || !text) return result;
  const auto tokens = h->sime->Tokenize(text);
  if (tokens.empty()) return result;
  result.items = static_cast<uint32_t *>(
      malloc(tokens.size() * sizeof(uint32_t)));
  if (!result.items) return result;
  memcpy(result.items, tokens.data(), tokens.size() * sizeof(uint32_t));
  result.count = static_cast<int>(tokens.size());
  return result;
}

void sime_free_tokens(SimeTokens *tokens) {
  if (!tokens) return;
  free(tokens->items);
  tokens->items = nullptr;
  tokens->count = 0;
}

static SimeResults to_c(const std::vector<sime::DecodeResult> &results) {
  SimeResults r;
  r.count = static_cast<int>(results.size());
  r.items = static_cast<SimeResult *>(
      malloc(static_cast<size_t>(r.count) * sizeof(SimeResult)));
  for (int i = 0; i < r.count; ++i) {
    const auto &src = results[static_cast<size_t>(i)];
    r.items[i].text = strdup(src.text.c_str());
    r.items[i].units = strdup(src.units.c_str());
    r.items[i].token_count = static_cast<int>(src.tokens.size());
    r.items[i].tokens = static_cast<uint32_t *>(
        malloc(src.tokens.size() * sizeof(uint32_t)));
    memcpy(r.items[i].tokens, src.tokens.data(),
           src.tokens.size() * sizeof(uint32_t));
    r.items[i].score = static_cast<float>(src.score);
    r.items[i].consumed = static_cast<int>(src.cnt);
  }
  return r;
}

SimeResults sime_decode_sentence(const SimeHandle *h, const char *input,
                                 int extra) {
  if (!h || !h->sime || !h->sime->Ready()) { SimeResults z{}; z.items=nullptr; z.count=0; return z; }
  return to_c(h->sime->DecodeSentence(input, static_cast<size_t>(extra)));
}

SimeResults sime_decode_sentence_with_context(
    const SimeHandle *h, const char *input, const uint32_t *context,
    int context_count, int extra) {
  if (!h || !h->sime || !h->sime->Ready() || !input) {
    SimeResults z{};
    z.items = nullptr;
    z.count = 0;
    return z;
  }
  std::vector<sime::TokenID> ctx;
  if (context && context_count > 0) {
    ctx.assign(context, context + context_count);
  }
  return to_c(h->sime->DecodeSentence(input, ctx,
                                      static_cast<size_t>(extra)));
}

SimeResults sime_decode_str(const SimeHandle *h, const char *input, int num) {
  if (!h || !h->sime || !h->sime->Ready()) { SimeResults z{}; z.items=nullptr; z.count=0; return z; }
  return to_c(h->sime->DecodeStr(input, static_cast<size_t>(num)));
}

SimeResults sime_decode_correction(const SimeHandle *h, const char *input,
                                   const char *fixed_prefix,
                                   int prefix_syllables, int num) {
  if (!h || !h->sime || !h->sime->Ready() || !input || !fixed_prefix ||
      prefix_syllables < 0 || num <= 0) {
    SimeResults z{};
    return z;
  }
  return to_c(h->sime->DecodeCorrection(
      input, fixed_prefix, static_cast<size_t>(prefix_syllables),
      static_cast<size_t>(num)));
}

SimeResults sime_next_tokens(const SimeHandle *h, const uint32_t *tokens,
                             int count, int num) {
  if (!h || !h->sime || !h->sime->Ready()) { SimeResults z{}; z.items=nullptr; z.count=0; return z; }
  std::vector<sime::TokenID> ctx(tokens, tokens + count);
  return to_c(h->sime->NextTokens(ctx, static_cast<size_t>(num)));
}

void sime_free_results(SimeResults *r) {
  if (!r || !r->items) return;
  for (int i = 0; i < r->count; ++i) {
    free(r->items[i].text);
    free(r->items[i].units);
    free(r->items[i].tokens);
  }
  free(r->items);
  r->items = nullptr;
  r->count = 0;
}

bool sime_load_user_sentence(SimeHandle *h, const char *path) {
  if (!h || !h->sime || !h->sime->Ready() || !path) return false;
  return h->sime->LoadUserSentence(path);
}

bool sime_save_user_sentence(const SimeHandle *h, const char *path) {
  if (!h || !h->sime || !h->sime->Ready() || !path) return false;
  return h->sime->SaveUserSentence(path);
}

void sime_set_user_sentence_enabled(SimeHandle *h, bool enabled) {
  if (!h || !h->sime || !h->sime->Ready()) return;
  h->sime->SetUserSentenceEnabled(enabled);
}

void sime_learn_user_sentence(SimeHandle *h,
                              const uint32_t *context, int context_count,
                              const uint32_t *tokens, int token_count) {
  if (!h || !h->sime || !h->sime->Ready()) return;
  if (!tokens || token_count <= 0) return;
  std::vector<sime::TokenID> ctx;
  if (context && context_count > 0) {
    ctx.assign(context, context + context_count);
  }
  std::vector<sime::TokenID> toks(tokens, tokens + token_count);
  h->sime->LearnUserSentence(ctx, toks);
}
