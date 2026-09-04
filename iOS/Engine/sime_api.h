#pragma once
// Pure C API for sime_core — imported by the Swift bridging header.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SimeHandle SimeHandle;

typedef struct {
  char *text;        // UTF-8 display text (malloc'd)
  char *units;       // segmented pinyin e.g. "ni'hao" (malloc'd)
  uint32_t *tokens;  // token IDs for LM context (malloc'd)
  int token_count;
  float score;
  int consumed;  // bytes of pinyin input consumed
} SimeResult;

typedef struct {
  SimeResult *items;  // malloc'd array
  int count;
} SimeResults;

typedef struct {
  uint32_t *items;  // malloc'd array
  int count;
} SimeTokens;

// Lifecycle
SimeHandle *sime_create(const char *dict_path, const char *cnt_path);
void sime_destroy(SimeHandle *h);
bool sime_ready(const SimeHandle *h);
int sime_context_size(const SimeHandle *h);
// Release the engine's internal trie/decode caches to shrink the resident
// footprint under memory pressure. Purely a memory hint: decode results are
// unchanged, caches simply rebuild on demand. Safe to call any time.
void sime_reset_caches(const SimeHandle *h);
// Segment already-written UTF-8 text for use as language-model context.
SimeTokens sime_tokenize_text(const SimeHandle *h, const char *text);
void sime_free_tokens(SimeTokens *tokens);

// Decoding
// decode_sentence: full Viterbi sentence decode; extra = number of N-best
// alternatives beyond the top result. `expansion` enables abbreviation/tail
// completion (a full-pinyin convenience); pass false for Shuangpin, whose
// syllables are fully typed and whose finals are already locked.
SimeResults sime_decode_sentence(const SimeHandle *h, const char *input,
                                 int extra, bool expansion);
SimeResults sime_decode_sentence_with_context(
    const SimeHandle *h, const char *input, const uint32_t *context,
    int context_count, int extra, bool expansion);
// decode_str: single-word / multi-word candidates (all starting at input[0])
SimeResults sime_decode_str(const SimeHandle *h, const char *input, int num);
// One ordered correction list: fixed_prefix remains unchanged and returned
// texts replace only the suffix at prefix_syllables. See above for expansion.
SimeResults sime_decode_correction(const SimeHandle *h, const char *input,
                                   const char *fixed_prefix,
                                   int prefix_syllables, int num,
                                   bool expansion);

// Prediction: given LM context token IDs, return likely next words.
SimeResults sime_next_tokens(const SimeHandle *h, const uint32_t *tokens,
                             int count, int num);

// Association (联想): next-word prediction merged with completion of the
// trailing context token. Each result's `consumed` is the number of leading
// characters of `text` already present in the document (0 for next-word),
// so the caller inserts `text` with its first `consumed` characters dropped.
SimeResults sime_associate(const SimeHandle *h, const uint32_t *tokens,
                           int count, int num);

// Free results returned by any of the above.
void sime_free_results(SimeResults *r);

// User-history LM (sentences.txt). Persists user picks across sessions
// so repeated bigrams get a score boost on next decode.
bool sime_load_user_sentence(SimeHandle *h, const char *path);
bool sime_save_user_sentence(const SimeHandle *h, const char *path);
void sime_set_user_sentence_enabled(SimeHandle *h, bool enabled);
void sime_learn_user_sentence(SimeHandle *h,
                              const uint32_t *context, int context_count,
                              const uint32_t *tokens, int token_count);

#ifdef __cplusplus
}
#endif
