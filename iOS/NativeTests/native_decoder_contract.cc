#include "sime.h"

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

void fail(const std::string& message) {
    std::cerr << "Native decoder contract failed: " << message << '\n';
    std::exit(1);
}

void expect_order(const sime::Sime& decoder, const std::string& pinyin,
                  const std::vector<std::string>& expected) {
    const auto results = decoder.DecodeStr(pinyin, expected.size());
    if (results.size() < expected.size()) {
        fail(pinyin + " returned only " + std::to_string(results.size()) + " candidates");
    }
    for (std::size_t index = 0; index < expected.size(); ++index) {
        if (results[index].text != expected[index]) {
            fail(pinyin + " candidate " + std::to_string(index) + " was "
                 + results[index].text + ", expected " + expected[index]);
        }
        if (results[index].cnt != pinyin.size()) {
            fail(pinyin + " candidate " + std::to_string(index)
                 + " consumed an unexpected source range");
        }
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: native_decoder_contract <sime.dict> <sime.cnt>\n";
        return 2;
    }

    const sime::Sime decoder(argv[1], argv[2]);
    if (!decoder.Ready()) fail("model did not become ready");

    // These snapshots deliberately cover stable, high-frequency results. A
    // model update that changes them must be reviewed rather than silently
    // changing the iOS candidate contract.
    expect_order(decoder, "nihao", {"你好", "你号", "倪浩"});
    expect_order(decoder, "zhongguo", {"中国", "中过", "种过"});
    expect_order(decoder, "xingjiabi", {"性价比", "型假币", "性假币"});
    expect_order(decoder, "womendezhongguo",
                 {"我们的中国", "我们地中国", "我们的中过"});

    std::cout << "Native decoder contract passed\n";
    return 0;
}
