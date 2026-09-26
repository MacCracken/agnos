#!/bin/sh
# check-array-sizing — the Cyrius var X[N] UNITS trap, gated.
#
# ⛔ FUNCTION-LOCAL `var X[N]` allocates N **BYTES**. MODULE-SCOPE `var X[N]` allocates N x u64
# (8N bytes). Same syntax, 8x difference, and the compiler says nothing.
#
# ⭐ THIS EXISTS BECAUSE IT COST AN IRON BURN'S CREDIBILITY. `gputri.cyr` declared a
# function-local `var sizes[8]` and stored six u64s into it at offsets 0..40 — 48 bytes into 8,
# a 40-byte smash over the saved registers. Every number the tool printed was CORRECT; only the
# EXIT CODE was wrong (142 instead of 95), because the corruption bit on the way out. A quieter
# version of the same bug corrupts a neighbouring buffer and reads as a hardware fault.
#
# ⚠ WIDTH-AWARE. The first version of this gate assumed every store was 8 bytes and reported 13
# false positives across the kernel — `store8(&candidates + 4, ..)` into `var candidates[5]` is
# perfectly correct. A gate that cries wolf gets muted, which is worse than no gate.
#
# ⛔ 1.57.7 — THE ALIAS, THE LOOP AND THE CALLEE. msc.cyr declared `var cdb_buf[2]` at all seven SCSI
# CDB builders and zeroed 16 bytes into each one — `var cdb_p = &cdb_buf;` then
# `while (k < 16) { store8(cdb_p + k, 0); k = k + 1; }`, or `msc_build_rw10_cdb(cdb_p, ..)`, whose own
# top-level loop does the same. A 14-byte overrun at seven sites, and this gate was GREEN on it: it saw
# only `store(&name + <literal>)` and `f(&name, <literal>)`, so an ALIAS, a LOOP BOUND and a CALLEE's
# writes were all invisible. The victim slot happened to be dead in all seven frames (measured,
# cycc 6.6.6); an `asm {}` in any of those bodies would have made INQUIRY DMA into phys 0.
#
# Conservative: a clean run is not proof of absence — but every hit is real. That is the doctrine every
# rule below is held to, and the reason each one prefers silence to a guess: a gate that reports one
# false positive gets muted, and a muted gate is no gate (the WIDTH-AWARE note above is that lesson).
#
# WHAT IS VISIBLE (a clean run means "no PROVABLE overrun" — never "no overrun"):
#   rule 1   direct literal offsets, `storeW(&x + LIT, ..)`, and the offset-0 form `storeW(&x, ..)`
#   rule 1′  the same through an alias `var p = &x;` (dropped if p is ever reassigned in x's scope)
#   rule 2   the buffer-and-length idiom `f(.., &x, LIT)` (&x second-to-last, a literal last)
#   rule 2′  the same with an alias in place of &x
#   rule 3   loop-bounded stores `storeW(&x|p + v ..)`, `+ v * M`, `+ LIT + v` inside
#            `while (v < N)` / `while (v <= N)` / `for (var v = S; v < N; v = v + K)` with a literal
#            bound N, a literal start S (the nearest preceding assignment) and a literal step K. A store
#            that follows the step in the body sees v one step further (`k = k + 1; store8(&x + k, ..)`
#            under `k < 16` reaches byte 17). The loop's OWN stated bound is the extent, exactly as
#            rule 2 takes the caller's stated length: a `break`/`return` or an `if` around the store
#            does not silence it (a bounded copy with a terminator into a too-small buffer is this class).
#   rule 4   unconditional top-level writes (function-body depth 1, or a literal-bounded loop headed
#            there that cannot `break`/`return`) through a parameter of a SAME-PROJECT callee
#            `f(.., &x|p, ..)`, up to the first `return` whose guard the CALLER's arguments can steer
#            (the guard's statement names a parameter, or a local assigned from one). A guard on runtime
#            state only — `if (pipe_buf == 0) { return 0 - 1; }` after a kmalloc — does not end it: the
#            success path writes, and a buffer is sized for the largest write any path can make.
#   rule 4b  a callee loop `while (v < n)` (v from 0, step 1) storing `param + v`, where the caller
#            passes the literal bound: `memset(&x, 0, 64)` into `var x[32]` needs 64
# STILL INVISIBLE (each is a real hole — do not read a PASS as covering it):
#   · loops with non-literal bounds or steps, `while (k != N)`, pointer-increment loops
#   · loop bounds that are module globals (e.g. `ext2_inode_size`)
#   · named-constant bounds over a local array (none today; the named-constant loops that exist, such
#     as power.cyr's `AHCI_MAX_PORTS`, index no local array)
#   · depth-2 (transitive) callees
#   · callee writes under a conditional — found-it out-params (`exfat_find_in_dir`, `fatfs_find_*`,
#     `route_next_hop_mac`) and every `ksyscall(K, ..)` dispatcher arm, e.g.
#     `ksyscall(25, &pfds..)` -> `vfs_create_pipe`; a callee loop that can `break`/`return` (rule 4
#     counts only writes every path makes); and callee writes after a `return` whose guard the
#     caller's arguments steer (`if (n < 32) { return 0; } store64(p + 24, 0);` called with n = 8
#     never writes — flagging it would be a false positive, so rule 4 stops at that return)
#   · offset arguments `f(&buf + K, ..)`
#   · calls with nested parentheses in the argument list
#   · lengths known only at run time
set -u
# ⚠ TWO levels up: this script lives in scripts/<group>/ since the 1.56.22 split.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# ⚠ 1.57.7 fix pass — THE CRASH PATHS THAT BYPASS THE PYTHON EXCEPTHOOK. The hook below turns a runtime
# exception into rc 5, but a missing python3 (rc 127) and a SyntaxError in this heredoc (rc 1, raised
# before the hook exists — the likeliest failure after a bad edit to this file) both used to print the
# OVERRUN wording with no site line under it. So: python3 is checked first, the output is captured (-u
# keeps stdout and stderr in order), and rc 1 counts as an overrun ONLY when the run printed its summary
# AND at least one `LOCAL var` line; any other rc 1 is a crash.
command -v python3 >/dev/null 2>&1 || {
    echo "  FAIL: python3 is not installed — check-array-sizing ran NOTHING; this run proves nothing"; exit 1; }
OUT=$(mktemp) || { echo "  FAIL: check-array-sizing could not create a temp file — this run proves nothing"; exit 1; }
trap 'rm -f "$OUT"' EXIT INT TERM
python3 -u - "$ROOT" > "$OUT" 2>&1 <<'PY'
import re,sys,glob,os,bisect
root=sys.argv[1]
# An uncaught exception would exit 1 — the OVERRUN code — and print the overrun FAIL line over a crash.
def _crash(t,v,tb):
    import traceback; traceback.print_exception(t,v,tb); sys.exit(5)
sys.excepthook=_crash
# ⛔⛔ 1.56.52 — THE GLOB WAS THE GATE'S BLIND SPOT, NOT THE RULES. It covered tests/gpu, kernel/core
# and kernel/arch/x86_64 ONLY — so `kernel/user/`, `kernel/klib/` and every SUBDIRECTORY
# (kernel/arch/x86_64/usb/, ...) were never scanned. That is where the bugs were: shell.cyr held FOUR
# ring-0 stack overflows of exactly the second rule's shape (`var cbuf[64]` handed to
# `vfs_read(fd, &cbuf, 512)`), one of them remotely triggered, and kfmt.cyr's callers held a 17-byte
# write into 16-byte buffers. Both rules below would have flagged them on the day they were written.
# A gate that is right and not pointed at the code is indistinguishable from no gate.
# ⚠ 1.57.7 — THREE GENERATED TREES ARE EXCLUDED: tests/<proj>/lib/ (the cyrius stdlib snapshot that
# `cyrius deps` rewrites per host — 187 files that are not agnos source and whose content depends on
# the machine), tests/<proj>/build/ and tests/gpu/gen/ (all three git-ignored, .gitignore). Scanning
# them made the gate's verdict host-dependent, and the 1.57.7 rule family produced three false
# positives there that are limits of this gate's shape, not stdlib defects: ws.cyr:210 (`var ext[2]`
# whose scope bled into a sibling arm under the old raw brace walk), ws_server.cyr:150, and
# yukti.cyr:2055 (`newfstatat(.., &stbuf, 256)` — 256 is AT_SYMLINK_NOFOLLOW, a flag, not a length).
def generated(rel):
    parts=rel.split('/')
    return parts[0]=='tests' and len(parts)>3 and parts[2] in ('lib','build','gen')
tests_f=sorted(p for p in glob.glob(root+'/tests/**/*.cyr', recursive=True)
               if not generated(os.path.relpath(p,root)))
kernel_f=sorted(glob.glob(root+'/kernel/**/*.cyr', recursive=True))
files=sorted(tests_f+kernel_f)

LIT=r'(?:0x[0-9a-fA-F]+|\d+)'
def lit(s): return int(s,16) if s.lower().startswith('0x') else int(s)
def islit(s): return re.fullmatch(LIT,s) is not None
KEYWORDS={'while','if','elif','for','return','fn','switch','else'}

# ⚠ 1.57.7 — THE BRACE WALK COUNTS CODE, NOT COMMENTS. The old walk counted every `{`/`}` on a line,
# comments and strings included: main.cyr:1501's comment `if (...) {` shifted the raw depth by +1 for
# the rest of the file (6,189 divergent lines across the tree, every later `fn` in main.cyr at depth
# 1). Rules 1/2 survived because the error was uniform; "top level = depth 1" (rule 4) does not. So
# string contents and `#` comments are stripped first, and the walk below asserts its own structure.
def strip(line):
    out=[]; i=0; n=len(line); ins=False
    while i<n:
        c=line[i]
        if ins:
            if c=='\\' and i+1<n: i+=2; continue
            if c=='"': ins=False; out.append('"')
            i+=1; continue
        if c=='"': ins=True; out.append('"'); i+=1; continue
        if c=='#': break
        out.append(c); i+=1
    return ''.join(out)

def first_arg(text,p):
    # p = index just after '(' ; return the text up to the first top-level ',' or the closing ')'
    d=0; q=p
    while q<len(text):
        c=text[q]
        if c=='(': d+=1
        elif c==')':
            if d==0: return text[p:q]
            d-=1
        elif c==',' and d==0: return text[p:q]
        elif c in '\n;{}': return None
        q+=1
    return None

def assigns(v):
    return re.compile(r'(?<![\w.])%s\s*=(?!=)'%re.escape(v))

class Src:
    def __init__(self,rel,raw_text,project):
        self.rel=rel; self.project=project
        raw=raw_text.split('\n'); self.raw=raw
        self.sl=[strip(l) for l in raw]
        self.text='\n'.join(self.sl)
        self.ls=[]; o=0
        for l in self.sl: self.ls.append(o); o+=len(l)+1
        t=self.text; cd=[0]*(len(t)+1); d=0
        for p,ch in enumerate(t):
            cd[p]=d
            if ch=='{': d+=1
            elif ch=='}': d-=1
        cd[len(t)]=d; self.cd=cd; self.final=d
        # dep[i] = depth at the start of line i; mind[i] = the minimum running depth within line i.
        self.dep=[]; self.mind=[]
        for i,l in enumerate(self.sl):
            d0=cd[self.ls[i]]; m=d0; dd=d0
            for ch in l:
                if ch=='{': dd+=1
                elif ch=='}': dd-=1; m=min(m,dd)
            self.dep.append(d0); self.mind.append(m)
        self.loops=self.parse_loops()
    def line_of(self,p): return bisect.bisect_right(self.ls,p)-1
    def close_of(self,b):
        # b = index of '{'; its matching '}'
        want=self.cd[b]+1; t=self.text
        for q in range(b+1,len(t)):
            if t[q]=='}' and self.cd[q]==want: return q
        return len(t)
    def scope_end(self,p,d):
        # first '}' at or after p that takes the depth below d (min-depth scope end: a `} elif (..) {`
        # line ends the arm's locals, so they never bleed into the sibling arm)
        # ⚠ SCOPE THE SEARCH TO THE ENCLOSING BLOCK, not the whole file. Two functions in one file may
        # each declare a local of the same name at DIFFERENT sizes — gpu.cyr has `var hdr[32]` read with
        # 32 and `var hdr[48]` read with 48, both correct — and a whole-file grep matches one's
        # declaration against the other's use. That false positive is indistinguishable from a real
        # smash by eye, and this gate's whole value is that every hit it reports is real. (1.57.7: the
        # sibling-arm case N5 in the corpus is the same lesson one level down.)
        t=self.text
        for q in range(p,len(t)):
            if t[q]=='}' and self.cd[q]<=d: return q
        return len(t)
    def fn_start(self,p):
        i=self.line_of(p)
        while i>0 and not re.match(r'fn\s',self.sl[i]): i-=1
        return self.ls[i]
    def start_value(self,v,hp):
        # nearest preceding assignment to v in the same function; it must be a literal at a depth no
        # deeper than the header's (a conditional reset is not a proven start) — else None (silence)
        fs=self.fn_start(hp); seg=self.text[fs:hp]
        last=None
        for m in re.finditer(r'(?<![\w.])(?:var\s+)?%s\s*=(?!=)\s*([^;]*);'%re.escape(v),seg): last=m
        if last is None: return None
        if self.cd[fs+last.start()]>self.cd[hp]: return None
        rhs=last.group(1).strip()
        return lit(rhs) if islit(rhs) else None
    def parse_loops(self):
        t=self.text; out=[]
        for m in re.finditer(r'\bwhile\s*\(\s*(\w+)\s*(<=|<)\s*(\w+)\s*\)\s*\{',t):
            v,op,bound=m.group(1),m.group(2),m.group(3)
            b=m.end()-1; e=self.close_of(b); body=t[b+1:e]
            L=dict(v=v,op=op,hp=m.start(),bs=b+1,be=e,hd=self.cd[m.start()],kind='while',
                   exits=re.search(r'\b(break|return)\b',body) is not None)
            asg=list(assigns(v).finditer(body))
            st=re.fullmatch(r'\s*%s\s*=\s*%s\s*\+\s*(%s)\s*'%(re.escape(v),re.escape(v),LIT),
                            body[asg[0].start():body.find(';',asg[0].start())]) if len(asg)==1 else None
            L['step']=lit(st.group(1)) if st else None
            # ⚠ 1.57.7 fix pass — WHERE THE STEP SITS MATTERS. `while (k < 16) { k = k + 1; store8(&x + k,
            # 0); }` stores at k = 1..16, i.e. 17 bytes; a store textually AFTER the step sees v one step
            # past the header's max. Positions are absolute text offsets; loop_max_at() applies it.
            L['stepp']=b+1+asg[0].start() if st else None
            L['start']=self.start_value(v,m.start())
            L['bound']=lit(bound) if islit(bound) else None
            L['bname']=None if islit(bound) else bound
            out.append(L)
        for m in re.finditer(r'\bfor\s*\(\s*var\s+(\w+)\s*=\s*(%s)\s*;\s*(\w+)\s*(<=|<)\s*(%s)\s*;\s*(\w+)\s*=\s*(\w+)\s*\+\s*(%s)\s*\)\s*\{'%(LIT,LIT,LIT),t):
            v=m.group(1)
            if m.group(3)!=v or m.group(6)!=v or m.group(7)!=v: continue
            b=m.end()-1; e=self.close_of(b); body=t[b+1:e]
            L=dict(v=v,op=m.group(4),hp=m.start(),bs=b+1,be=e,hd=self.cd[m.start()],kind='for',
                   exits=re.search(r'\b(break|return)\b',body) is not None,
                   step=lit(m.group(8)) if not list(assigns(v).finditer(body)) else None,
                   stepp=None,   # a `for` steps in its header, after the body
                   start=lit(m.group(2)),bound=lit(m.group(5)),bname=None)
            out.append(L)
        for L in out:
            L['max']=None
            if L['bound'] is not None and L['step'] and L['step']>0 and L['start'] is not None:
                lim=L['bound']+(1 if L['op']=='<=' else 0)
                if lim-1>=L['start']:
                    L['max']=L['start']+((lim-1-L['start'])//L['step'])*L['step']
        return out
    def enclosing(self,q):
        return [L for L in self.loops if L['bs']<=q<L['be']]

def loop_max_at(L,q):
    # the largest value v holds at a store at text offset q inside L's body
    return L['max']+(L['step'] if L['stepp'] is not None and q>L['stepp'] else 0)

def loop_lv(loops,q):
    # loop var -> (its max at the store at q, the loop)
    return {L['v']:(loop_max_at(L,q),L) for L in loops}

def loop_desc(L,q=None):
    after=q is not None and L['stepp'] is not None and q>L['stepp']
    s="%s %s %s %d, step %d"%(L['kind'],L['v'],L['op'],L['bound'],L['step'])
    return s+(", the store follows the step" if after else "")

def arg_extent(arg,ptrs,lv):
    # arg = a store's first argument; ptrs = names that point at offset 0 of the object;
    # lv = loop var -> (max value at this store, loop). Returns (bytes-offset, loops used) or None when
    # any term is not provably known.
    a=re.sub(r'\s+',' ',arg.strip())
    if '-' in a or '(' in a: return None
    terms=[x.strip() for x in a.split('+')]
    if terms[0].replace(' ','') not in ptrs: return None
    tot=0; used=[]
    for x in terms[1:]:
        if islit(x): tot+=lit(x); continue
        m=re.fullmatch(r'(\w+)\s*\*\s*(%s)'%LIT,x) or re.fullmatch(r'(%s)\s*\*\s*(\w+)'%LIT,x)
        if m:
            g1,g2=m.group(1),m.group(2)
            vv,mm=(g1,g2) if not islit(g1) else (g2,g1)
            if vv in lv: tot+=lv[vv][0]*lit(mm); used.append(lv[vv][1]); continue
            return None
        if x in lv: tot+=lv[x][0]; used.append(lv[x][1]); continue
        return None
    return tot,used

STORE=re.compile(r'\bstore(8|16|32|64)\s*\(')
CALL=re.compile(r'(\w+)\(([^()]*)\)')

def steered_return(src,b,e,params,ptr):
    # ⚠ 1.57.7 fix pass — rule 4 counts a callee's depth-1 writes as UNCONDITIONAL, and a write after
    # `if (n < 32) { return 0; }` is not: called with n = 8 it never happens, and reporting it would break
    # "every hit is real". So the unconditional region ends at the first `return` whose guard the CALLER
    # can steer: the depth-1 statement holding it (from its line start to the `return`) names a parameter
    # or a local assigned from one. A return guarded on runtime state alone (`if (pipe_buf == 0)` after a
    # kmalloc, vfs_create_pipe) does NOT end it — the success path still writes, and a buffer is sized for
    # the largest write any path can make. A depth-1 `return` ends it outright (nothing after it runs).
    # Taint is propagated in text order through `var x = ..;` / `x = ..;` (over-tainting only adds silence).
    # ONE EXEMPTION, per written parameter `ptr`: a null test on that very pointer (`if (out == 0) { return
    # 0; }`, hid_mouse_take) naming nothing else the caller steers — a `&local` is never 0, so that guard
    # never fires for the callers this rule measures. Without it the cut cost the live syscall.cyr
    # `var pscr[24]` <- hid_mouse_take pair (measured: callee pairs 21 -> 20).
    t=src.text; body=t[b+1:e]
    taint={p for p in params if re.fullmatch(r'\w+',p)}
    def names(s): return set(re.findall(r'\b[A-Za-z_]\w*\b',s))
    events=[(m.start(),'a',m) for m in re.finditer(r'(?<![\w.=!<>])(?:var\s+)?(\w+)\s*=(?!=)\s*([^;]*);',body)]
    events+=[(m.start(),'r',m) for m in re.finditer(r'\breturn\b',body)]
    for pos,kind,m in sorted(events,key=lambda x:x[0]):
        if kind=='a':
            if names(m.group(2))&taint: taint.add(m.group(1))
            continue
        q=b+1+pos
        if src.cd[q]<=1: return q
        i=src.line_of(q)
        while i>0 and src.dep[i]>1: i-=1   # the depth-1 statement that holds this return
        st=t[src.ls[i]:q]; hit=names(st)&taint
        if hit=={ptr} and re.match(r'\s*if\s*\(\s*%s\s*==\s*0\s*\)\s*\{'%re.escape(ptr),st): continue
        if hit: return q
    return e

def fn_defs(src):
    # pass 1 of rules 4/4b: per `^fn name(params)`, the unconditional per-parameter write extent and
    # the param-bounded writer loops.
    t=src.text; out=[]
    for i,l in enumerate(src.sl):
        m=re.match(r'fn\s+(\w+)\s*\(',l)
        if not m or src.dep[i]!=0: continue
        p0=src.ls[i]+m.end(); d=0; q=p0
        while q<len(t) and not (t[q]==')' and d==0):
            if t[q]=='(': d+=1
            elif t[q]==')': d-=1
            q+=1
        params=[x.strip() for x in t[p0:q].split(',')] if t[p0:q].strip() else []
        b=t.find('{',q)
        if b<0: continue
        e=src.close_of(b); body=t[b+1:e]; base=b+1
        ext=[0]*len(params); w4b=[]
        for j,p in enumerate(params):
            if not re.fullmatch(r'\w+',p): continue
            cut=steered_return(src,b,e,params,p)
            if re.search(r'(?<![\w.])(?:var\s+)?%s\s*=(?!=)'%re.escape(p),body): continue   # reassigned: silence
            ptrs={p}
            for am in re.finditer(r'\bvar\s+(\w+)\s*=\s*%s\s*;'%re.escape(p),body):
                A=am.group(1)
                if len(list(assigns(A).finditer(body)))==1: ptrs.add(A)   # only its own `var A =`
            for sm in STORE.finditer(body):
                q2=base+sm.start(); W=int(sm.group(1))//8
                if q2>=cut: break   # past a return the caller's arguments steer: not unconditional
                arg=first_arg(t,base+sm.end())
                if arg is None: continue
                dq=src.cd[q2]
                if dq==1:
                    r=arg_extent(arg,ptrs,{})
                    if r: ext[j]=max(ext[j],r[0]+W)
                elif dq==2:
                    enc=[L for L in src.enclosing(q2) if L['hd']==1]
                    if len(enc)==1 and not enc[0]['exits'] and enc[0]['max'] is not None:
                        r=arg_extent(arg,ptrs,loop_lv(enc,q2))
                        if r: ext[j]=max(ext[j],r[0]+W)
            # rule 4b: `while (v < pb)` headed at depth 1, v from 0, step 1, storing `pj + v`
            for L in src.loops:
                if not (b<L['hp']<e and L['hd']==1 and L['bname'] in params and L['op']=='<'
                        and L['start']==0 and L['step']==1): continue
                for sm in STORE.finditer(t,L['bs'],L['be']):
                    arg=first_arg(t,sm.end())
                    if arg is None: continue
                    a=re.sub(r'\s+','',arg)
                    if any(a==P+'+'+L['v'] for P in ptrs):
                        w4b.append((j,params.index(L['bname']),int(sm.group(1))//8))
        out.append((m.group(1),params,ext,w4b))
    return out

def analyse(srcs,counters):
    # returns {(rel,line): dict(name,n,needs{rule:(need,msg)})}
    defs={}
    for s in srcs:
        for name,params,ext,w4b in fn_defs(s):
            D=defs.setdefault(s.project,{}).setdefault(name,{'ext':[],'w4b':set()})
            if len(D['ext'])<len(ext): D['ext']+= [0]*(len(ext)-len(D['ext']))
            for j,x in enumerate(ext): D['ext'][j]=max(D['ext'][j],x)
            D['w4b'].update(w4b)
    res={}
    for s in srcs:
        t=s.text; PD=defs.get(s.project,{})
        for i,l in enumerate(s.sl):
            m=re.search(r'^\s+var (\w+)\[(\d+)\]',l)
            if not m or s.dep[i]<=0: continue
            counters['decls']+=1
            name,n=m.group(1),int(m.group(2))
            dp=s.ls[i]+m.start(1); d=s.dep[i]
            end=s.scope_end(dp,d); seg=t[dp:end]
            key=(s.rel,i+1); rec=dict(name=name,n=n,needs={})
            def need(rule,v,msg):
                if v>rec['needs'].get(rule,(0,''))[0]: rec['needs'][rule]=(v,msg)
            amp='&'+name
            aliases=[]
            for am in re.finditer(r'\bvar\s+(\w+)\s*=\s*&\s*%s\s*;'%re.escape(name),seg):
                A=am.group(1)
                rest=seg[am.end():]
                if not assigns(A).search(rest): aliases.append(A)
            if aliases: counters['aliased']+=1
            ptrs={amp}|set(aliases)
            # rules 1 / 1′ — literal offsets (the pre-1.57.7 prefix match) and the offset-0 form
            for P in [amp]+aliases:
                pp=r'&\s*%s'%re.escape(name) if P==amp else re.escape(P)
                rule='1' if P==amp else '1′'
                for sm in re.finditer(r'\bstore(8|16|32|64)\(\s*%s\s*\+\s*(%s)'%(pp,LIT),seg):
                    W=int(sm.group(1)); v=lit(sm.group(2))+W//8
                    need(rule,v,"a store%d%s reaches byte %d (rule %s)"%(W,'' if P==amp else ' through '+P,v,rule))
                for sm in re.finditer(r'\bstore(8|16|32|64)\(\s*%s\s*,'%pp,seg):
                    W=int(sm.group(1)); v=W//8
                    need(rule,v,"a store%d%s at offset 0 reaches byte %d (rule %s)"%(W,'' if P==amp else ' through '+P,v,rule))
            # rule 3 — loop-bounded stores
            # ⚠ 1.57.7 fix pass: NO break/return exclusion here (spec §2.5; it had been added in the step
            # and hid the bounded-copy-with-terminator shape). The loop's own literal bound is the stated
            # extent, as rule 2 takes a caller's stated length. Corpus P11 pins it.
            for sm in STORE.finditer(t,dp,end):
                enc=[L for L in s.enclosing(sm.start()) if L['max'] is not None]
                if not enc: continue
                arg=first_arg(t,sm.end())
                if arg is None: continue
                r=arg_extent(arg,ptrs,loop_lv(enc,sm.start()))
                if not r or not r[1]: continue
                counters['loop']+=1
                W=int(sm.group(1)); v=r[0]+W//8
                via=re.sub(r'\s+','',arg).split('+')[0]
                need('3',v,"a loop-bounded store%d through %s reaches byte %d (rule 3: %s)"
                     %(W,via,v,'; '.join(loop_desc(L,sm.start()) for L in r[1])))
            # rules 2 / 2′ / 4 / 4b — call sites
            # ⛔⛔ SECOND RULE — THE BUFFER-AND-LENGTH IDIOM, added 2026-07-27 AFTER AN IRON BURN.
            # Rule 1 can only see stores written DIRECTLY to the named array. It is blind to an array
            # passed BY ADDRESS to something that writes it, which is how the same bug class reached
            # silicon a second time: gputex.cyr's seam case declared `var o1[16]` and handed &o1 to
            # tl_op0c(), which writes a 64-byte op record — a 48-byte smash the gate could not see, and
            # the burn came back `the SOLO list-B call was REJECTED` because the overflow corrupted the
            # locals the NEXT record was built from.
            # `f(&buf, LEN)` with a literal LEN is the one indirect form that states its own size, so it
            # is checkable exactly and with no guessing: the array must hold LEN bytes. (Rules 4/4b,
            # 1.57.7, reach the writers that take no length.)
            # ⚠ THE OBVIOUS REGEX IS WRONG, AND IT CRIED WOLF FOUR TIMES BEFORE THIS COMMENT EXISTED.
            # `&name\s*,\s*(\d+)\)` also matches `store8(&msg, 72)`, where 72 is the byte VALUE — so it
            # flagged main.cyr's "HI"/"PI" literals, net_dhcp's option code 53 and a gpu.cyr header read,
            # all correct code. That is precisely the failure the header records the FIRST version of
            # this gate making. So: parse CALL SITES, skip store*/load*, and require &buf (or, since
            # 1.57.7, an alias of it) to be the SECOND-TO-LAST argument with a literal length LAST — the
            # real buffer-and-length idiom and nothing else.
            for cm in CALL.finditer(seg):
                callee=cm.group(1)
                if callee in KEYWORDS: continue
                args=[x.strip() for x in cm.group(2).split(',')]
                argn=[re.sub(r'\s+','',x) for x in args]
                # ⚠ DECIMAL ONLY, as it always was: a hex literal in last position is a VALUE in this tree
                # (`nic_send(.., &kmac, 0x0806)` is an ethertype), and a length idiom that reads values
                # cries wolf. Corpus case N6 holds that line.
                if not (callee.startswith('store') or callee.startswith('load')) and len(args)>=2 \
                   and argn[-2] in ptrs and re.fullmatch(r'\d+',args[-1]):
                    v=int(args[-1]); rule='2' if argn[-2]==amp else '2′'
                    need(rule,v,"is passed%s with an explicit length of %d (rule %s)"
                         %('' if rule=='2' else ' through '+argn[-2],v,rule))
                D=PD.get(callee)
                if not D: continue
                for j,a in enumerate(argn):
                    if a not in ptrs: continue
                    if j<len(D['ext']) and D['ext'][j]>0:
                        counters['callee']+=1; v=D['ext'][j]
                        need('4',v,"it is passed to %s (arg %d), which writes %d bytes through it unconditionally (rule 4)"%(callee,j,v))
                    for (pj,pb,W) in D['w4b']:
                        if pj==j and pb<len(args) and islit(args[pb]):
                            counters['bounded']+=1; L=lit(args[pb])
                            if L<=0: continue
                            v=L-1+W
                            need('4b',v,"it is passed to %s (arg %d) with the literal bound %d at arg %d, and %s's loop writes %d bytes through it (rule 4b)"%(callee,j,L,pb,callee,v))
            res[key]=rec
    return res

def offenders(res):
    out=[]
    for key in sorted(res):
        rec=res[key]; n=rec['n']
        over={r:v for r,v in rec['needs'].items() if v[0]>n}
        if not over: continue
        worst=max(over.items(),key=lambda kv:kv[1][0])
        also=['rule %s need %d'%(r,v[0]) for r,v in sorted(over.items()) if r!=worst[0]]
        out.append((key,rec,worst,over,also))
    return out

# ---- CONTROL CORPUS: runs FIRST, through the same functions. A rule that cannot see its own positive
# control is blind, and a gate whose rule is blind prints the same PASS as a clean tree.
# ⛔ 1.57.7 fix pass — EACH POSITIVE CASE PINS THE EXTENT, NOT JUST THE HIT. The corpus used to count hits,
# and every positive sized its buffer far below the need ([2] for 16), so a rule that dropped the store
# WIDTH still "saw" its control: measured, a rule-3 mutant with `v=r[0]` and a rules-1/4/4b mutant with the
# width dropped both passed 14/14 while going silent on `var cdb_buf[15]` under a 16-byte zero loop — a
# 1-byte overrun, the size of kfmt.cyr's real one. Now a positive case (need > 0) passes only if the single
# declaration is flagged by THAT rule with EXACTLY that need, and every positive is sized need-1 (the
# boundary), so an off-by-anything in either direction is a CONTROL failure. A negative (need 0) passes
# only if nothing at all is flagged. Tuples: (case, rule, exact need or 0, snippet).
CORPUS=[
 ('P1','3',16,'''fn c_p1() {
    var cdb_buf[15];
    var cdb_p = &cdb_buf;
    var k = 0;
    while (k < 16) { store8(cdb_p + k, 0); k = k + 1; }
    store8(cdb_p + 0, 0x12);
    return 0;
}'''),
 ('P2','4',16,'''fn c_w16(p) {
    var k = 0;
    while (k < 16) { store8(p + k, 0); k = k + 1; }
    return 0;
}
fn c_p2() {
    var b[15];
    c_w16(&b);
    return 0;
}'''),
 ('P3','4b',6,'''fn c_z(dst, n) {
    var i = 0;
    while (i < n) { store8(dst + i, 0); i = i + 1; }
    return 0;
}
fn c_p3() {
    var b[5];
    c_z(&b, 6);
    return 0;
}'''),
 ('P4','1′',5,'''fn c_p4() {
    var b[4];
    var p = &b;
    store8(p + 4, 1);
    return 0;
}'''),
 ('P5','3',64,'''fn c_p5() {
    var b[63];
    for (var i = 0; i < 8; i = i + 1) { store64(&b + i * 8, 0); }
    return 0;
}'''),
 ('P6','1',8,'''fn c_p6() {
    var b[7];
    store64(&b, 1);
    return 0;
}'''),
 ('P6b','1',16,'''fn c_p6b() {
    var b[15];
    store64(&b + 8, 0);
    return 0;
}'''),
 ('P7','2′',32,'''fn c_p7() {
    var b[31];
    var p = &b;
    c_f(p, 32);
    return 0;
}'''),
 ('P7b','2',32,'''fn c_p7b() {
    var b[31];
    c_f(&b, 32);
    return 0;
}'''),
 ('P8','4',16,'''# if (x) {   <- a comment brace: the raw walk put every fn below at depth 1
fn c_w16b(p) {
    store64(p, 0);
    store64(p + 8, 0);
    return 0;
}
fn c_p8() {
    var b[15];
    c_w16b(&b);
    return 0;
}'''),
 ('P9','3',17,'''fn c_p9() {
    var b[16];
    var k = 0;
    while (k < 16) { k = k + 1; store8(&b + k, 0); }
    return 0;
}'''),
 ('P10','4',17,'''fn c_w17(p) {
    var k = 0;
    while (k < 16) { k = k + 1; store8(p + k, 0); }
    return 0;
}
fn c_p10() {
    var b[16];
    c_w17(&b);
    return 0;
}'''),
 ('P11','3',64,'''fn c_p11(s) {
    var b[63];
    var i = 0;
    while (i < 64) { var c = load8(s + i); if (c == 0) { break; } store8(&b + i, c); i = i + 1; }
    return 0;
}'''),
 ('P12','4',16,'''fn c_pipe(fds) {
    var m = c_alloc(4096);
    if (m == 0) { return 0 - 1; }
    var r = c_fd();
    if (r < 0) { c_free(m); return 0 - 1; }
    store64(fds, r);
    store64(fds + 8, r + 1);
    return 0;
}
fn c_p12() {
    var pf[15];
    c_pipe(&pf);
    return 0;
}'''),
 ('N1','3',0,'''fn c_n1() {
    var snap[32];
    var si = 0;
    while (si < 32) { store64(&snap + si, 0); si = si + 8; }
    return 0;
}'''),
 ('N2','4',0,'''fn c_disp(num, arg2) {
    if (num == 5) { store64(arg2 + 8, 0); }
    return 0;
}
fn c_n2() {
    var x[8];
    c_disp(5, &x);
    return 0;
}'''),
 ('N3','3',0,'''fn c_rw10(cdb_p, opcode, lba, count) {
    var k = 0;
    while (k < 16) { store8(cdb_p + k, 0); k = k + 1; }
    store8(cdb_p + 0, opcode);
    store8(cdb_p + 8,  count       & 0xFF);
    return 0;
}
fn c_n3(lba, count) {
    var cdb_buf[16];
    var cdb_p = &cdb_buf;
    var k = 0;
    while (k < 16) { store8(cdb_p + k, 0); k = k + 1; }
    store8(cdb_p + 4, 36);
    c_rw10(cdb_p, 0x28, lba, count);
    return 0;
}'''),
 ('N4','1′',0,'''fn c_n4() {
    var b[4];
    var other[16];
    var p = &b;
    p = &other;
    store8(p + 12, 0);
    return 0;
}'''),
 ('N5','2',0,'''fn c_n5(a, c) {
    if (a) {
        var e[2];
        c_g(&e, 2);
    } elif (c) {
        var e[8];
        c_g(&e, 8);
    }
    return 0;
}'''),
 ('N6','2',0,'''fn c_n6(p) {
    var kmac[8];
    c_send(p, 42, &kmac, 0x0806);
    return 0;
}'''),
 ('N7','4b',0,'''fn c_z7(dst, n) {
    var i = 0;
    while (i < n) { store8(dst + i, 0); i = i + 1; }
    return 0;
}
fn c_n7() {
    var b[6];
    c_z7(&b, 6);
    return 0;
}'''),
 ('N8','4',0,'''fn c_w8(p, n) {
    if (n < 32) { return 0; }
    store64(p + 24, 0);
    return 0;
}
fn c_n8() {
    var b[8];
    c_w8(&b, 8);
    return 0;
}'''),
 ('N9','4',0,'''fn c_cp9(p, s) {
    var k = 0;
    while (k < 64) { if (load8(s + k) == 0) { break; } store8(p + k, 0); k = k + 1; }
    return 0;
}
fn c_n9(s) {
    var b[16];
    c_cp9(&b, s);
    return 0;
}'''),
]
cfail=0; cpass=0
for cid,rule,exp,snip in CORPUS:
    s=Src('corpus/'+cid,snip,'corpus-'+cid)
    offs=offenders(analyse([s],{'decls':0,'aliased':0,'loop':0,'callee':0,'bounded':0}))
    if exp>0:
        hit=[o for o in offs if rule in o[3]]
        got=hit[0][3][rule][0] if len(hit)==1 else ('%d hits'%len(hit))
        good=len(offs)==1 and len(hit)==1 and got==exp
        what='need %d'%exp
    else:
        got='%d hit(s)'%len(offs); good=not offs; what='silence'
    if good: cpass+=1
    else:
        sys.stderr.write("  CONTROL: rule %s case %s expected %s got %s\n"%(rule,cid,what,got)); cfail=1
# ⚠ 1.57.7 fix pass — A CONTROL FAILURE NO LONGER ENDS THE RUN. The tree is still scanned and every
# overrun line and the summary are printed (spec §2.5 "overrun lines are printed in every case"); the
# exit code then takes the precedence corpus 3 > structure 4 > vacuity 2 > overrun 1. An early exit here
# hid real overruns behind a gate-self failure: M5 on the unfixed tree printed three CONTROL lines and not
# one of the seven msc.cyr sites.

# ⚠ VACUITY FLOOR — THE GLOB IS ALSO HOW THIS GATE PASSES ON NOTHING, AND THE 1.56.52 REPAIR ABOVE
# ADDED PATHS WITHOUT ADDING ONE. An EMPTY `files` walks straight to exit 0 and the shell below prints
# "PASS: no function-local var X[N] overruns" — the identical green line a clean full sweep prints.
# Two concrete ways that already exist here:
#   · ROOT IS COMPUTED TWO LEVELS UP FROM $0 (and the 1.56.22 split is exactly the edit that
#     changed how many levels that is). Move, copy or symlink this script one directory over and ROOT
#     lands on a tree with no kernel/ and no tests/ — both globs return [], and the gate reports the
#     kernel clean. Measured 2026-09-02: this script, unmodified, sitting at scripts/check/ in a tree
#     whose two-levels-up ROOT holds neither directory printed the PASS line and exited 0 having
#     opened zero files.
#   · DROP THE `**/` (or rename/move either half) and the enumeration collapses to the 3 top-level
#     kernel/*.cyr files across 1 directory, tests/ contributing 0 — a 99%-blind gate that still
#     prints PASS. That is the SAME failure the header records costing four ring-0 stack overflows in
#     kernel/user/, one remotely triggered.
# So the enumeration is asserted and PRINTED rather than implied: a run that says "3 files across 1
# directory" is reporting that its own glob broke, not that the kernel is clean. Floors are
# STRUCTURAL, not hand-tuned counts that would rot as the tree grows — each half must contribute, and
# the sweep must reach SUBDIRECTORIES, which is the entire content of the 1.56.52 fix.
# ⚠ AND HERE IS WHAT THIS FLOOR DOES **NOT** CATCH, MEASURED 2026-09-02 SO NOBODY RE-DERIVES IT:
# deleting only `recursive=True` does NOT empty the sweep — bare `**` degrades to `*`, so the globs
# still return a large fraction of the files and pass every floor here. A floor is an anti-vacuity
# assertion, not a coverage assertion: it proves this run READ SOMETHING, never that it read
# everything. Do not raise these numbers toward the live counts to chase that — a floor tuned to
# today's tree fails on the day a subsystem is legitimately retired, and a gate that cries wolf gets
# muted, which the header above already records this file learning the hard way.
# (measured 315 declarations / 162 files across 22 directories at 1.57.7, generated trees excluded)
ndirs=len(set(os.path.dirname(p) for p in files))
if len(tests_f)<1 or len(kernel_f)<1 or ndirs<4:
    sys.stderr.write(
        "  VACUOUS: enumerated %d .cyr file(s) across %d director(ies) "
        "(tests/ %d, kernel/ %d) under %s\n"
        %(len(files),ndirs,len(tests_f),len(kernel_f),root))
    sys.stderr.write("  This gate is vacuous below one file per half and 4 directories: the tree has\n")
    sys.stderr.write("  kernel/{core,klib,user,arch/*,shaders/emit} plus one tests/* project per\n")
    sys.stderr.write("  subsystem. Finding fewer means the glob or ROOT broke, not that the code is clean.\n")
    vac0=1
else:
    vac0=0

srcs=[]; sfail=0
for p in files:
    rel=os.path.relpath(p,root)
    parts=rel.split('/')
    proj='kernel' if parts[0]=='kernel' else 'tests/'+parts[1]
    s=Src(rel,open(p,encoding='utf-8',errors='replace').read(),proj)
    srcs.append(s)
    # STRUCTURAL SELF-CHECK: with comments and strings stripped every `fn` sits at depth 0 and every
    # file ends at depth 0. If not, local scopes are wrong and so is every verdict below.
    for i,l in enumerate(s.raw):
        if l.startswith('fn ') and s.dep[i]!=0:
            sys.stderr.write("  STRUCTURE: %s:%d fn at depth %d\n"%(rel,i+1,s.dep[i])); sfail=1
    if s.final!=0:
        sys.stderr.write("  STRUCTURE: %s ends at depth %d\n"%(rel,s.final)); sfail=1
# (no early exit on sfail: the overrun lines below are printed in every case, then 4 outranks them)

C={'decls':0,'aliased':0,'loop':0,'callee':0,'bounded':0}
res=analyse(srcs,C)
offs=offenders(res)
for (rel,ln),rec,worst,over,also in offs:
    print("  %s:%d  LOCAL var %s[%d] = %d BYTES but %s%s"
          %(rel,ln,rec['name'],rec['n'],rec['n'],worst[1][1],
            ('  [also: '+', '.join(also)+']') if also else ''))
print("  scanned %d file(s) across %d dir(s) (tests/ %d, kernel/ %d), %d local declaration(s); "
      "measured: loop %d, callee %d, bounded %d, aliased %d; control corpus %d/%d"
      %(len(files),ndirs,len(tests_f),len(kernel_f),C['decls'],C['loop'],C['callee'],C['bounded'],
        C['aliased'],cpass,len(CORPUS)))
# ⚠ SECOND FLOOR — THE FILES CAN BE THERE AND THE RULES STILL RUN ON NOTHING. Every rule hangs off
# ONE regex, `^\s+var (\w+)\[(\d+)\]`, which is indentation-sensitive BY DESIGN (the leading \s+ is
# what distinguishes a function-local — N bytes — from a module-scope declaration at column 0 — 8N
# bytes; that distinction is this gate's entire subject). So the day the formatter, a syntax change,
# or a `let`/`var` rename moves that shape, every declaration stops matching, every rule iterates zero
# times, and the gate prints PASS over a fully-populated sweep. So the count of declarations ACTUALLY
# EXAMINED is asserted too — and since 1.57.7 each new rule asserts its OWN measurements, because a
# rule whose parse rotted matches nothing while its siblings still run.
vac=vac0
if C['decls']<1 and not vac0:
    sys.stderr.write("  VACUOUS: scanned %d .cyr file(s) but matched ZERO function-local "
                     "`var X[N]` declarations\n"%len(files))
    sys.stderr.write("  Every rule keys off that one regex; zero matches means the parse rotted, not\n")
    sys.stderr.write("  that the kernel declares no local arrays. Real tree: 315 declarations (1.57.7).\n")
    vac=1
for rule,k,what in (('3','loop','loop-bounded store measurements'),
                    ('4','callee','(local, callee arg) pairs with a non-zero extent'),
                    ('4b','bounded','(local, param-bounded writer) calls with a literal bound')):
    if C[k]<1 and not vac0:
        sys.stderr.write("  VACUOUS: rule %s evaluated 0 %s — the rule matched nothing, the parse rotted\n"%(rule,what))
        vac=1
# Precedence (spec §2.5): a broken control (3) or a broken walk (4) means no verdict below can be
# trusted, a vacuous rule (2) means part of the tree was not measured; only then does an overrun decide.
if cfail: sys.exit(3)
if sfail: sys.exit(4)
if vac: sys.exit(2)
sys.exit(1 if offs else 0)
PY
rc=$?; prc=$rc
cat "$OUT"
if [ "$rc" -eq 1 ] && ! { grep -q '^  scanned ' "$OUT" && grep -q ' LOCAL var ' "$OUT"; }; then rc=5; fi
if [ "$rc" -eq 0 ]; then echo "  PASS: no function-local var X[N] overruns"; exit 0; fi
# ⚠ A VACUOUS OR BROKEN RUN IS NOT A CLEAN RUN, AND MUST NOT BORROW THE OVERRUN WORDING. check.sh logs
# this script to /tmp/check-array-sizing.log and prints the log on failure (1.57.7 — until then it
# invoked it as `>/dev/null 2>&1`, so a red run showed no site lines). The floors, the control corpus
# and the structure check still fail CLOSED (rc 2/3/4 -> exit 1), because a warning scrolls past.
case "$rc" in
2) echo "  FAIL: check-array-sizing measured nothing for at least one rule or the enumeration — this run verified NO code there (see stderr)" ;;
3) echo "  FAIL: a rule failed its own control case — the gate is broken, not the kernel; this run proves nothing" ;;
4) echo "  FAIL: the brace walk could not place every fn at depth 0 — local scopes are wrong; this run proves nothing" ;;
1) echo "  FAIL: a function-local array is smaller than a write the gate can prove" ;;
*) echo "  FAIL: check-array-sizing crashed or could not run (python rc $prc; traceback or error above) — this run proves nothing" ;;
esac
exit 1
