// C wrapper around sime_core for Swift interop.

#include "sime_api.h"
#include "sime.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

// The C bridge is a strict noexcept boundary: no C++ exception may cross into
// Swift (that would terminate the process), and every allocation is checked so
// an out-of-memory condition (likely in a memory-constrained keyboard
// extension) degrades to an empty result instead of a null-pointer write.
namespace {

SimeResults empty_results() {
  SimeResults r{};
  r.items = nullptr;
  r.count = 0;
  return r;
}

SimeTokens empty_tokens() {
  SimeTokens t{};
  t.items = nullptr;
  t.count = 0;
  return t;
}

// Run `f` and never let an exception escape to the C caller. The result type
// is deduced from `fallback`, so pass a fallback of the exact return type.
template <class R, class F>
R guard(F &&f, R fallback) noexcept {
  try {
    return f();
  } catch (...) {
    return fallback;
  }
}

}  // namespace

// sime::Sime holds DoubleArray by value (copy/move-deleted), so we wrap it in
// a unique_ptr to avoid assignment.
struct SimeHandle {
  std::unique_ptr<sime::Sime> sime;
};

SimeHandle *sime_create(const char *dict_path, const char *cnt_path) {
  return guard([&]() -> SimeHandle * {
    if (!dict_path || !cnt_path) return nullptr;
    auto h = std::make_unique<SimeHandle>();
    h->sime = std::make_unique<sime::Sime>(dict_path, cnt_path);
    return h.release();
  }, static_cast<SimeHandle *>(nullptr));
}

void sime_destroy(SimeHandle *h) { delete h; }

bool sime_ready(const SimeHandle *h) { return h && h->sime && h->sime->Ready(); }

int sime_context_size(const SimeHandle *h) {
  return (h && h->sime) ? h->sime->ContextSize() : 0;
}

void sime_reset_caches(const SimeHandle *h) {
  if (h && h->sime) h->sime->ResetCaches();
}

SimeTokens sime_tokenize_text(const SimeHandle *h, const char *text) {
  return guard([&]() -> SimeTokens {
    SimeTokens result = empty_tokens();
    if (!h || !h->sime || !h->sime->Ready() || !text) return result;
    const auto tokens = h->sime->Tokenize(text);
    if (tokens.empty()) return result;
    auto *items = static_cast<uint32_t *>(
        malloc(tokens.size() * sizeof(uint32_t)));
    if (!items) return result;
    memcpy(items, tokens.data(), tokens.size() * sizeof(uint32_t));
    result.items = items;
    result.count = static_cast<int>(tokens.size());
    return result;
  }, empty_tokens());
}

void sime_free_tokens(SimeTokens *tokens) {
  if (!tokens) return;
  free(tokens->items);
  tokens->items = nullptr;
  tokens->count = 0;
}

static SimeResults to_c(const std::vector<sime::DecodeResult> &results) {
  if (results.empty()) return empty_results();
  const size_t n = results.size();
  // calloc zero-inits every field so partial cleanup can free() safely.
  auto *items = static_cast<SimeResult *>(calloc(n, sizeof(SimeResult)));
  if (!items) return empty_results();
  for (size_t i = 0; i < n; ++i) {
    const auto &src = results[i];
    char *text = strdup(src.text.c_str());
    char *units = strdup(src.units.c_str());
    uint32_t *tokens = nullptr;
    bool tokens_ok = true;
    if (!src.tokens.empty()) {
      tokens = static_cast<uint32_t *>(
          malloc(src.tokens.size() * sizeof(uint32_t)));
      if (tokens) {
        memcpy(tokens, src.tokens.data(),
               src.tokens.size() * sizeof(uint32_t));
      } else {
        tokens_ok = false;
      }
    }
    // Any failed allocation makes the whole call fail atomically: free this
    // row's partials and every previously built row, then return empty.
    if (!text || !units || !tokens_ok) {
      free(text);
      free(units);
      free(tokens);
      for (size_t j = 0; j < i; ++j) {
        free(items[j].text);
        free(items[j].units);
        free(items[j].tokens);
      }
      free(items);
      return empty_results();
    }
    items[i].text = text;
    items[i].units = units;
    items[i].token_count = static_cast<int>(src.tokens.size());
    items[i].tokens = tokens;
    items[i].score = static_cast<float>(src.score);
    items[i].consumed = static_cast<int>(src.cnt);
  }
  SimeResults r{};
  r.items = items;
  r.count = static_cast<int>(n);
  return r;
}

SimeResults sime_decode_sentence(const SimeHandle *h, const char *input,
                                 int extra, bool expansion) {
  return guard([&]() -> SimeResults {
    if (!h || !h->sime || !h->sime->Ready() || !input || extra < 0)
      return empty_results();
    return to_c(h->sime->DecodeSentence(input, static_cast<size_t>(extra),
                                        expansion));
  }, empty_results());
}

SimeResults sime_decode_sentence_with_context(
    const SimeHandle *h, const char *input, const uint32_t *context,
    int context_count, int extra, bool expansion) {
  return guard([&]() -> SimeResults {
    if (!h || !h->sime || !h->sime->Ready() || !input || extra < 0)
      return empty_results();
    std::vector<sime::TokenID> ctx;
    if (context && context_count > 0) {
      ctx.assign(context, context + context_count);
    }
    return to_c(h->sime->DecodeSentence(input, ctx,
                                        static_cast<size_t>(extra), expansion));
  }, empty_results());
}

SimeResults sime_decode_str(const SimeHandle *h, const char *input, int num) {
  return guard([&]() -> SimeResults {
    if (!h || !h->sime || !h->sime->Ready() || !input || num <= 0)
      return empty_results();
    return to_c(h->sime->DecodeStr(input, static_cast<size_t>(num)));
  }, empty_results());
}

SimeResults sime_decode_correction(const SimeHandle *h, const char *input,
                                   const char *fixed_prefix,
                                   int prefix_syllables, int num,
                                   bool expansion) {
  return guard([&]() -> SimeResults {
    if (!h || !h->sime || !h->sime->Ready() || !input || !fixed_prefix ||
        prefix_syllables < 0 || num <= 0) {
      return empty_results();
    }
    return to_c(h->sime->DecodeCorrection(
        input, fixed_prefix, static_cast<size_t>(prefix_syllables),
        static_cast<size_t>(num), expansion));
  }, empty_results());
}

SimeResults sime_next_tokens(const SimeHandle *h, const uint32_t *tokens,
                             int count, int num) {
  return guard([&]() -> SimeResults {
    if (!h || !h->sime || !h->sime->Ready() || !tokens || count <= 0 ||
        num <= 0)
      return empty_results();
    std::vector<sime::TokenID> ctx(tokens, tokens + count);
    return to_c(h->sime->NextTokens(ctx, static_cast<size_t>(num)));
  }, empty_results());
}

SimeResults sime_associate(const SimeHandle *h, const uint32_t *tokens,
                           int count, int num) {
  return guard([&]() -> SimeResults {
    if (!h || !h->sime || !h->sime->Ready() || !tokens || count <= 0 ||
        num <= 0)
      return empty_results();
    std::vector<sime::TokenID> ctx(tokens, tokens + count);
    return to_c(h->sime->Associate(ctx, static_cast<size_t>(num)));
  }, empty_results());
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
  return guard([&]() -> bool {
    if (!h || !h->sime || !h->sime->Ready() || !path) return false;
    return h->sime->LoadUserSentence(path);
  }, false);
}

bool sime_save_user_sentence(const SimeHandle *h, const char *path) {
  return guard([&]() -> bool {
    if (!h || !h->sime || !h->sime->Ready() || !path) return false;
    return h->sime->SaveUserSentence(path);
  }, false);
}

void sime_set_user_sentence_enabled(SimeHandle *h, bool enabled) {
  guard([&]() -> bool {
    if (!h || !h->sime || !h->sime->Ready()) return false;
    h->sime->SetUserSentenceEnabled(enabled);
    return true;
  }, false);
}

void sime_learn_user_sentence(SimeHandle *h,
                              const uint32_t *context, int context_count,
                              const uint32_t *tokens, int token_count) {
  guard([&]() -> bool {
    if (!h || !h->sime || !h->sime->Ready()) return false;
    if (!tokens || token_count <= 0) return false;
    std::vector<sime::TokenID> ctx;
    if (context && context_count > 0) {
      ctx.assign(context, context + context_count);
    }
    std::vector<sime::TokenID> toks(tokens, tokens + token_count);
    h->sime->LearnUserSentence(ctx, toks);
    return true;
  }, false);
}
