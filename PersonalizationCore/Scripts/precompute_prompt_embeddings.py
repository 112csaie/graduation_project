"""預先計算分類文字向量，寫入 App 內附的 PhotoAI.sqlite（資料表 PrecomputedPromptEmbeddings）。

為什麼：手機第一次分類前要把 200 多條分類描述轉成文字向量；預先算好放進 App，手機就不必現算。
怎麼算：直接讀 App 裡的 mobileclip_s2_text.mlpackage（MIL 程式 + 權重），用 numpy 依同一張運算圖計算；
        tokenizer 是 MobileCLIPExplore/Tokenizer/CLIPTokenizer.swift 的 Python 版。
        寫入前會拿 SemanticDictionary（App 用 CoreML 算出的既有向量）抽樣比對，餘弦相似度必須 ≥ 0.9999，否則不寫入。
只新增／更新 PrecomputedPromptEmbeddings 一張表，不動其他資料表。

需求：python3、numpy、protobuf，以及 coremltools 的 proto 定義（不需要安裝 coremltools 本體）：
    git clone --depth 1 --filter=blob:none --sparse https://github.com/apple/coremltools /tmp/cmltools
    (cd /tmp/cmltools && git sparse-checkout set coremltools/proto)
    mkdir -p /tmp/pbpkg/coremltools && cp -r /tmp/cmltools/coremltools/proto /tmp/pbpkg/coremltools/
    touch /tmp/pbpkg/coremltools/__init__.py /tmp/pbpkg/coremltools/proto/__init__.py

用法（在 ios_app 目錄）：
    python3 PersonalizationCore/Scripts/precompute_prompt_embeddings.py . --proto-path /tmp/pbpkg
分類目錄（TaxonomyCatalog.swift）新增或修改描述後重新執行即可；沒有預算到的描述，App 仍會在手機上補算。
"""
import argparse, hashlib, os, sqlite3
import json, re, struct, sys
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("root", help="ios_app 目錄")
parser.add_argument("--proto-path", required=True, help="含 coremltools/proto/*_pb2.py 的目錄")
parser.add_argument("--dry-run", action="store_true", help="只計算與驗證，不寫入資料庫")
ARGS = parser.parse_args()
sys.path.insert(0, ARGS.proto_path)
from coremltools.proto import Model_pb2, MIL_pb2  # noqa: E402

ROOT = os.path.abspath(ARGS.root)
PKG = os.path.join(ROOT, 'MobileCLIPExplore/Models/mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/')
RES = os.path.join(ROOT, 'MobileCLIPExplore/Resources/')
DB = os.path.join(ROOT, 'MobileCLIPExplore/SQLite/PhotoAI.sqlite')
CATALOG = os.path.join(ROOT, 'PersonalizationCore/Sources/PersonalizationCore/TaxonomyCatalog.swift')

DT = MIL_pb2.DataType
NP = {DT.FLOAT16: np.float16, DT.FLOAT32: np.float32, DT.FLOAT64: np.float64, DT.INT8: np.int8,
      DT.INT16: np.int16, DT.INT32: np.int32, DT.INT64: np.int64, DT.UINT8: np.uint8, DT.BOOL: np.bool_}


# ---------------- tokenizer (port of CLIPTokenizer.swift) ----------------
def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b); cs.append(256 + n); n += 1
    return dict(zip(bs, [chr(c) for c in cs]))


class Tokenizer:
    def __init__(self):
        lines = [l for l in open(os.path.join(RES, 'clip-merges.txt'), encoding='utf-8').read().split('\n') if l != '']
        self.ranks = {tuple(lines[i].split(' ')): i - 1 for i in range(1, len(lines))}
        self.encoder = json.load(open(os.path.join(RES, 'clip-vocab.json'), encoding='utf-8'))
        self.byte_encoder = bytes_to_unicode()
        # Swift: <|startoftext|>|<|endoftext|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+
        self.pat = re.compile(r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[^\W\d_]+|\d|[^\s\w]+|_+")

    def bpe(self, token):
        if len(token) <= 1:
            return token + '</w>'
        word = list(token[:-1]) + [token[-1] + '</w>']
        while True:
            pairs = {(word[i], word[i + 1]) for i in range(len(word) - 1)}
            cand = [p for p in pairs if p in self.ranks]
            if not cand:
                break
            first, second = min(cand, key=lambda p: self.ranks[p])
            new, i = [], 0
            while i < len(word):
                try:
                    j = word.index(first, i)
                    new.extend(word[i:j]); i = j
                except ValueError:
                    new.extend(word[i:]); break
                if word[i] == first and i < len(word) - 1 and word[i + 1] == second:
                    new.append(first + second); i += 2
                else:
                    new.append(word[i]); i += 1
            word = new
            if len(word) == 1:
                break
        return ' '.join(word)

    def encode_full(self, text):
        assert text.isascii(), text   # prompts are English; non-ASCII \p{L}/\p{N} edge cases are not needed
        ids = []
        for tok in self.pat.findall(text.lower()):
            enc = ''.join(self.byte_encoder[b] for b in tok.encode('utf-8'))
            ids += [self.encoder[t] for t in self.bpe(enc).split(' ') if t in self.encoder]
        full = [0] * 77
        full[0] = self.encoder['<|startoftext|>']
        full[1:1 + len(ids)] = ids
        full[len(ids) + 1] = self.encoder['<|endoftext|>']
        return full


# ---------------- MIL interpreter ----------------
class TextEncoder:
    def __init__(self):
        m = Model_pb2.Model()
        m.ParseFromString(open(os.path.join(PKG, 'model.mlmodel'), 'rb').read())
        f = m.mlProgram.functions['main']
        self.ops = list(f.block_specializations[f.opset].operations)
        self.output = list(f.block_specializations[f.opset].outputs)[0]
        self.blob = open(os.path.join(PKG, 'weights/weight.bin'), 'rb').read()
        self.consts = {}
        for op in self.ops:
            if op.type == 'const':
                self.consts[op.outputs[0].name] = self._const(op)

    def _const(self, op):
        ttype = op.outputs[0].type.tensorType
        if ttype.dataType == DT.STRING:
            return op.attributes['val'].immediateValue.tensor.strings.values[0]
        dtype = NP[ttype.dataType]
        shape = [d.constant.size for d in ttype.dimensions]
        v = op.attributes['val']
        kind = v.WhichOneof('value')
        if kind == 'blobFileValue':
            sentinel, _mil_dtype, size, data_off = struct.unpack_from('<IIQQ', self.blob, v.blobFileValue.offset)
            assert sentinel == 0xDEADBEEF
            arr = np.frombuffer(self.blob, dtype=dtype, count=size // np.dtype(dtype).itemsize, offset=data_off)
            return arr.reshape(shape).astype(np.float32 if dtype == np.float16 else dtype)
        tv = v.immediateValue.tensor
        which = tv.WhichOneof('value')
        if which == 'bytes':
            arr = np.frombuffer(tv.bytes.values, dtype=dtype)
        elif which == 'strings':
            return tv.strings.values[0] if not shape else list(tv.strings.values)
        else:
            arr = np.array(list(getattr(tv, which).values), dtype=dtype)
        arr = arr.reshape(shape) if shape else arr.reshape(())
        return arr.astype(np.float32) if dtype == np.float16 else arr

    def run(self, tokens):
        env = dict(self.consts)
        env['text'] = np.array([tokens], dtype=np.int32)
        for op in self.ops:
            if op.type == 'const':
                continue
            a = {}
            for k, arg in op.inputs.items():
                vals = [env[b.name] for b in arg.arguments]
                a[k] = vals if k == 'values' else vals[0]
            env[op.outputs[0].name] = getattr(self, 'op_' + op.type)(**a)
        return env[self.output]

    # ops
    def op_gather(self, x, indices, axis, batch_dims=0, validate_indices=None):
        return np.take(x, indices, axis=int(axis))
    def op_add(self, x, y): return x + y
    def op_mul(self, x, y): return x * y
    def op_layer_norm(self, x, axes, gamma=None, beta=None, epsilon=1e-5):
        axes = tuple(int(i) for i in np.atleast_1d(axes))
        mean = x.mean(axis=axes, keepdims=True)
        var = ((x - mean) ** 2).mean(axis=axes, keepdims=True)
        y = (x - mean) / np.sqrt(var + float(epsilon))
        return y * gamma + beta
    def op_linear(self, x, weight, bias=None):
        y = x @ weight.T
        return y + bias if bias is not None else y
    def op_reshape(self, x, shape):
        shape = [int(s) for s in shape]
        shape = [x.shape[i] if s == 0 else s for i, s in enumerate(shape)]
        return x.reshape(shape)
    def op_transpose(self, x, perm): return np.transpose(x, [int(p) for p in perm])
    def op_slice_by_index(self, x, begin, end, stride=None, begin_mask=None, end_mask=None, squeeze_mask=None):
        n = x.ndim
        stride = np.ones(n, int) if stride is None else stride
        begin_mask = np.zeros(n, bool) if begin_mask is None else begin_mask
        end_mask = np.zeros(n, bool) if end_mask is None else end_mask
        squeeze_mask = np.zeros(n, bool) if squeeze_mask is None else squeeze_mask
        sl = []
        for i in range(n):
            b = None if begin_mask[i] else int(begin[i])
            e = None if end_mask[i] else int(end[i])
            sl.append(slice(b, e, int(stride[i])))
        y = x[tuple(sl)]
        sq = tuple(i for i in range(n) if squeeze_mask[i])
        return np.squeeze(y, axis=sq) if sq else y
    def op_matmul(self, x, y, transpose_x=False, transpose_y=False):
        if transpose_x: x = np.swapaxes(x, -1, -2)
        if transpose_y: y = np.swapaxes(y, -1, -2)
        return x @ y
    def op_softmax(self, x, axis):
        z = x - x.max(axis=int(axis), keepdims=True)
        e = np.exp(z)
        return e / e.sum(axis=int(axis), keepdims=True)
    def op_gelu(self, x, mode='EXACT'):
        if mode == 'EXACT':
            try:
                from scipy.special import erf
            except ImportError:   # Abramowitz–Stegun 7.1.26（誤差 < 1.5e-7）
                def erf(z):
                    sgn = np.sign(z); z = np.abs(z)
                    t = 1 / (1 + 0.3275911 * z)
                    y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * np.exp(-z * z)
                    return sgn * y
            return 0.5 * x * (1 + erf(x / np.sqrt(2)))
        if mode == 'TANH_APPROXIMATION':
            return 0.5 * x * (1 + np.tanh(np.sqrt(2 / np.pi) * (x + 0.044715 * x ** 3)))
        return x / (1 + np.exp(-1.702 * x))
    def op_reduce_argmax(self, x, axis, keep_dims=False):
        return np.argmax(x, axis=int(axis), keepdims=bool(keep_dims)).astype(np.int32)
    def op_stack(self, values, axis): return np.stack(values, axis=int(axis))
    def op_gather_nd(self, x, indices, batch_dims=0, validate_indices=None):
        idx = indices.reshape(-1, indices.shape[-1])
        out = np.stack([x[tuple(i)] for i in idx])
        return out.reshape(indices.shape[:-1] + x.shape[indices.shape[-1]:])
    def op_cast(self, x, dtype): return x.astype(np.float32) if dtype in ('fp32', 'fp16') else x


def normalized(v):
    v = np.asarray(v, dtype=np.float32).reshape(-1)
    return v / np.linalg.norm(v)


def catalog_prompts():
    s = open(CATALOG, encoding='utf-8').read()
    prompts = []
    for m in re.finditer(r'\.(?:visual|assisted|derived|manualOnly),\s*\[(.*?)\]', s, re.S):
        prompts += re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))
    return sorted(set(p.strip() for p in prompts))


def table_hashes(con):
    out = {}
    for (t,) in con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name <> 'PrecomputedPromptEmbeddings'"):
        out[t] = hashlib.md5(repr(con.execute(f'SELECT * FROM "{t}" ORDER BY rowid').fetchall()).encode()).hexdigest()
    return out


def main():
    tok, enc = Tokenizer(), TextEncoder()
    embed = lambda text: normalized(enc.run(tok.encode_full("a photo of " + text.strip())))

    con = sqlite3.connect(DB)
    # 1. 驗證：與 App（CoreML）既有算出的 SemanticDictionary 向量比對
    sample = con.execute("""SELECT keyword, word_embedding FROM SemanticDictionary
                            WHERE word_embedding IS NOT NULL ORDER BY keyword LIMIT 40""").fetchall()
    sims = []
    for keyword, blob in sample:
        if not ("a photo of " + keyword).isascii():
            continue
        ref = np.frombuffer(blob, dtype=np.float32)
        sims.append(float(embed(keyword) @ (ref / np.linalg.norm(ref))))
    print(f"驗證：{len(sims)} 筆，最低餘弦相似度 {min(sims):.7f}，平均 {np.mean(sims):.7f}")
    if not sims or min(sims) < 0.9999:
        print("❌ 與 App 的 CoreML 結果不一致，不寫入資料庫。")
        return 1

    # 2. 計算分類描述
    prompts = catalog_prompts()
    vectors = {p: embed(p) for p in prompts}
    print(f"計算完成：{len(vectors)} 條分類描述")
    if ARGS.dry_run:
        return 0

    # 3. 寫入（只動 PrecomputedPromptEmbeddings）
    before = table_hashes(con)
    with con:
        con.execute("""CREATE TABLE IF NOT EXISTS PrecomputedPromptEmbeddings (
            prompt TEXT PRIMARY KEY, embedding BLOB NOT NULL, template TEXT NOT NULL, model TEXT NOT NULL)""")
        for p, v in vectors.items():
            con.execute("INSERT OR REPLACE INTO PrecomputedPromptEmbeddings VALUES (?, ?, 'a photo of', 'mobileclip_s2_text.mlpackage')",
                        (p, v.astype('<f4').tobytes()))
    assert table_hashes(con) == before, "其他資料表不應變動"
    con.execute("VACUUM")
    print("✅ 已寫入 PhotoAI.sqlite（其他資料表未變動）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
