import contextlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import msvcrt
except ImportError:
    msvcrt = None

try:
    import fcntl
except ImportError:
    fcntl = None

USER_AGENT = "mpv-lazy-bangumi-sync/1.0 (https://github.com/bangumi/api)"
API_BASE = "https://api.bgm.tv"


def out_json(obj):
    sys.stdout.buffer.write((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
            return data if isinstance(data, type(default)) else default
    except Exception:
        return default


def save_json(path, data):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    tmp_path = f"{path}.{os.getpid()}.{time.time_ns()}.tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


@contextlib.contextmanager
def file_lock(lock_path, timeout=5.0):
    parent = os.path.dirname(os.path.abspath(lock_path))
    os.makedirs(parent, exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
    locked = False
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                if msvcrt is not None:
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                elif fcntl is not None:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("文件锁超时，请稍后重试")
                time.sleep(0.05)
        yield
    finally:
        if locked:
            try:
                if msvcrt is not None:
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
                elif fcntl is not None:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        os.close(fd)


def api_request(method, path, token=None, body=None, query=None):
    url = API_BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    headers = {
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    data_bytes = None
    if body is not None:
        data_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data_bytes, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=18) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            if not raw.strip():
                return resp.status, {}
            return resp.status, json.loads(raw)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw) if raw.strip() else {}
        except Exception:
            payload = {"message": raw[:200]}
        return e.code, payload
    except Exception as e:
        return 0, {"message": str(e)}


def parse_episode_and_title(filepath, hint_anime=""):
    base = os.path.splitext(os.path.basename(filepath))[0]
    folder = os.path.basename(os.path.dirname(filepath))

    # Strip release group tags and technical suffixes for clean matching
    def clean(s):
        s = re.sub(r"^(\[[^\]]*\]|\([^)]*\)|【[^】]*】)\s*", "", s)
        s = re.sub(r"(\[[^\]]*\]|\([^)]*\)|【[^】]*】)", " ", s)
        s = re.sub(r"\b(1080p|2160p|720p|4K|WEB-?DL|BDRip|BluRay|HEVC|H\.?264|H\.?265|x264|x265|AAC[\d.]*|FLAC|CR|AMZN|NF|B-Global|CHT|CHS|GB|BIG5|10bit|8bit)\b.*", "", s, flags=re.I)
        s = re.sub(r"[._]+", " ", s)
        return re.sub(r"\s+", " ", s).strip(" -_")

    season = None
    episode = None
    title = ""

    patterns = [
        r"^(?P<t>.+?)[._\s-]+S(?P<s>\d{1,2})[._\s-]*E(?P<e>\d{1,3}(?:\.5)?)(?=[^0-9]|$)",
        r"^(?P<t>.+?)[._\s-]+第\s*(?P<s>\d{1,2})\s*[季部][._\s-]+第?\s*(?P<e>\d{1,3}(?:\.5)?)\s*[话集回]?",
        r"^(?P<t>.+?)[._\s-]+(?:EP?\.?\s*)(?P<e>\d{1,3}(?:\.5)?)(?=[^0-9]|$)",
        r"^(?P<t>.+?)[._\s-]*第\s*(?P<e>\d{1,3}(?:\.5)?)\s*[话集回]",
        r"^(?P<t>.+?)\s*\[(?P<e>\d{1,3}(?:\.5)?)(?:v\d+)?\]",
        r"^(?P<t>.+?)\s*-\s*(?P<e>\d{1,3}(?:\.5)?)(?:\s|$)",
    ]

    for pat in patterns:
        m = re.search(pat, base, flags=re.I)
        if m:
            gd = m.groupdict()
            title = clean(gd.get("t") or "")
            if gd.get("s"):
                season = int(gd["s"])
            if gd.get("e"):
                try:
                    episode = float(gd["e"])
                    if episode.is_integer():
                        episode = int(episode)
                except Exception:
                    pass
            break

    if not title:
        title = clean(base)
    if (not title or len(title) < 2) and folder:
        title = clean(folder)

    if hint_anime and hint_anime.strip():
        title = hint_anime.strip()

    return title, season, episode


def search_subjects(keyword, token=None):
    status, data = api_request(
        "POST",
        "/v0/search/subjects",
        token=token,
        body={"keyword": keyword, "filter": {"type": [2]}},
        query={"limit": 12},
    )
    if status == 401 and token:
        status, data = api_request(
            "POST",
            "/v0/search/subjects",
            token=None,
            body={"keyword": keyword, "filter": {"type": [2]}},
            query={"limit": 12},
        )
    if status < 200 or status >= 300:
        return None, data.get("description") or data.get("message") or f"HTTP {status}"
    items = []
    for s in data.get("data") or []:
        items.append({
            "id": s.get("id"),
            "name": s.get("name") or "",
            "name_cn": s.get("name_cn") or s.get("name") or "",
            "date": s.get("date") or "",
            "eps": s.get("eps") or s.get("total_episodes") or 0,
        })
    return items, None


def cmd_status(cfg_dir):
    auth = load_json(os.path.join(cfg_dir, "bangumi-auth.json"), {})
    user = auth.get("user")
    if auth.get("token") and isinstance(user, dict) and user.get("username"):
        out_json({
            "ok": True,
            "logged_in": True,
            "username": user.get("username"),
            "nickname": user.get("nickname") or user.get("username"),
        })
    else:
        out_json({"ok": True, "logged_in": False})


def cmd_login(cfg_dir, token):
    token = (token or "").strip()
    if not token:
        out_json({"ok": False, "error": "Access Token 不能为空"})
        return
    status, user = api_request("GET", "/v0/me", token=token)
    if status < 200 or status >= 300 or not isinstance(user, dict) or not user.get("username"):
        msg = (user.get("description") or user.get("message")) if isinstance(user, dict) else ""
        if status == 401:
            msg = "Token 无效或已过期，请重新生成"
        out_json({"ok": False, "error": msg or f"登录验证失败 (HTTP {status})"})
        return
    save_json(os.path.join(cfg_dir, "bangumi-auth.json"), {"token": token, "user": user})
    out_json({
        "ok": True,
        "username": user.get("username"),
        "nickname": user.get("nickname") or user.get("username"),
    })


def cmd_logout(cfg_dir):
    p = os.path.join(cfg_dir, "bangumi-auth.json")
    if os.path.exists(p):
        os.remove(p)
    out_json({"ok": True})


def cmd_search(cfg_dir, keyword):
    auth = load_json(os.path.join(cfg_dir, "bangumi-auth.json"), {})
    items, err = search_subjects(keyword, auth.get("token"))
    if err:
        out_json({"ok": False, "error": err})
        return
    out_json({"ok": True, "items": items})


def cmd_bind_folder(cfg_dir, folder_key, subject_id, subject_name, ep_num=None, filepath=None):
    mp = os.path.join(cfg_dir, "bangumi-map.json")
    lock_path = os.path.join(cfg_dir, "_cache", "bangumi-map.lock")
    norm_key = os.path.normpath(folder_key).lower()
    try:
        with file_lock(lock_path):
            mapping = load_json(mp, {})
            mapping[norm_key] = {"id": int(subject_id), "name": subject_name}
            save_json(mp, mapping)
    except Exception as e:
        out_json({"ok": False, "error": str(e) or "写入关联映射失败"})
        return

    resolved_ep = None
    resolved_season = None
    if ep_num is not None and str(ep_num).strip() != "":
        try:
            fval = float(str(ep_num).strip())
            resolved_ep = int(fval) if fval.is_integer() else fval
        except Exception:
            resolved_ep = None

    if resolved_ep is None and filepath and str(filepath).strip() != "":
        try:
            _, parsed_season, parsed_ep = parse_episode_and_title(filepath, subject_name or "")
            resolved_ep = parsed_ep
            resolved_season = parsed_season or 1
        except Exception:
            pass

    ep_title = ""
    if resolved_ep is not None:
        try:
            auth = load_json(os.path.join(cfg_dir, "bangumi-auth.json"), {})
            ep_obj, _ = get_episode_info(cfg_dir, subject_id, resolved_ep, auth.get("token"), allow_cache=True)
            ep_title = extract_ep_title(ep_obj)
        except Exception:
            ep_title = ""

    out_json({
        "ok": True,
        "episode": resolved_ep,
        "season": resolved_season,
        "episode_title": ep_title,
    })


def extract_ep_title(ep_obj):
    if not isinstance(ep_obj, dict):
        return ""
    return (ep_obj.get("name_cn") or ep_obj.get("name") or "").strip()


def find_episode_in_list(episodes, target_ep):
    sort_match = None
    for ep in episodes or []:
        try:
            if ep.get("ep") is not None and abs(float(ep["ep"]) - target_ep) < 1e-6:
                return ep
            if sort_match is None and ep.get("sort") is not None and abs(float(ep["sort"]) - target_ep) < 1e-6:
                sort_match = ep
        except Exception:
            continue
    return sort_match


def fetch_subject_episodes(subject_id, token=None):
    sid = int(subject_id)
    all_eps = []
    offset = 0
    complete = False
    for _ in range(50):
        status, obj = api_request(
            "GET",
            "/v0/episodes",
            token=token,
            query={"subject_id": sid, "type": 0, "limit": 100, "offset": offset},
        )
        if status == 401 and token:
            token = None
            status, obj = api_request(
                "GET",
                "/v0/episodes",
                token=None,
                query={"subject_id": sid, "type": 0, "limit": 100, "offset": offset},
            )
        if status < 200 or status >= 300:
            if status == 0:
                return None, False, "网络请求失败"
            msg = obj.get("description") or obj.get("message") or f"HTTP {status}"
            return None, False, msg
        batch = obj.get("data") or []
        for ep in batch:
            all_eps.append({
                "id": ep.get("id"),
                "ep": ep.get("ep"),
                "sort": ep.get("sort"),
                "name_cn": (ep.get("name_cn") or "").strip(),
                "name": (ep.get("name") or "").strip(),
            })
        offset += len(batch)
        total = obj.get("total")
        if not batch or (total is not None and offset >= int(total)):
            complete = True
            break
    return all_eps, complete, None


def get_episode_info(cfg_dir, subject_id, ep_num, token=None, allow_cache=True):
    try:
        sid = int(subject_id)
        target_ep = float(ep_num)
    except Exception:
        return None, "集数格式无效"

    cache_path = os.path.join(cfg_dir, "_cache", "bangumi-episodes-cache.json")
    cache = load_json(cache_path, {})
    sid_key = str(sid)
    now = int(time.time())

    if allow_cache and sid_key in cache and isinstance(cache[sid_key], dict):
        entry = cache[sid_key]
        age = now - int(entry.get("ts") or 0)
        is_complete = bool(entry.get("complete", True))
        found = find_episode_in_list(entry.get("episodes"), target_ep)
        if found:
            has_title = bool(extract_ep_title(found))
            if (has_title and age < 7 * 86400) or age < 3 * 3600:
                return found, None
        elif is_complete and age < 3 * 3600:
            return None, None

    episodes, complete, err = fetch_subject_episodes(sid, token=token)
    if err is not None:
        # Fallback to stale cache if available when offline
        if sid_key in cache and isinstance(cache[sid_key], dict):
            stale = find_episode_in_list(cache[sid_key].get("episodes"), target_ep)
            if stale:
                return stale, None
        return None, err

    cache[sid_key] = {"ts": now, "complete": complete, "episodes": episodes}
    if len(cache) > 200:
        ordered = sorted(cache.items(), key=lambda kv: int((kv[1] or {}).get("ts") or 0), reverse=True)
        cache = dict(ordered[:200])
    try:
        save_json(cache_path, cache)
    except Exception:
        pass

    return find_episode_in_list(episodes, target_ep), None


def pick_best_subject(items, season):
    cn_nums = {2: "二", 3: "三", 4: "四", 5: "五", 6: "六"}
    sequel_re = re.compile(r"(第\s*[2-9二三四五六七八九]\s*[期季部]|[2-9]\s*期|Season\s*[2-9]|2nd|3rd|4th|\bII\b|\bIII\b)", re.I)
    spinoff_re = re.compile(r"(～|迷你|小剧场|OVA|OAD|剧场版|总集篇|特典|PV|CM|番外|●●)", re.I)

    def score(idx, item):
        text = f"{item.get('name_cn') or ''} {item.get('name') or ''}"
        s = 100 - idx * 3
        eps = int(item.get("eps") or 0)
        if eps >= 8:
            s += 12
        elif eps == 0:
            s -= 15
        if spinoff_re.search(text):
            s -= 35

        if season and season >= 2:
            cn = cn_nums.get(season, str(season))
            pat = re.compile(rf"(第\s*({season}|{cn})\s*[期季部]|{season}\s*期|Season\s*{season})", re.I)
            if pat.search(text):
                s += 55
            elif not sequel_re.search(text):
                s -= 20
        else:
            # Season 1 or unspecified: strongly prefer original season 1 over sequels
            if sequel_re.search(text):
                s -= 45
            else:
                s += 20
        return s

    ranked = sorted(enumerate(items), key=lambda pair: score(pair[0], pair[1]), reverse=True)
    return ranked[0][1]


def cmd_match(cfg_dir, filepath, hint_anime=""):
    auth = load_json(os.path.join(cfg_dir, "bangumi-auth.json"), {})
    token = auth.get("token")
    folder_key = os.path.normpath(os.path.dirname(filepath)).lower()
    mapping = load_json(os.path.join(cfg_dir, "bangumi-map.json"), {})

    title, season, episode = parse_episode_and_title(filepath, hint_anime)

    def resolve_title(sid):
        if not sid or episode is None:
            return ""
        try:
            ep_obj, _ = get_episode_info(cfg_dir, sid, episode, token, allow_cache=True)
            return extract_ep_title(ep_obj)
        except Exception:
            return ""

    if folder_key in mapping:
        saved = mapping[folder_key]
        sid = saved.get("id")
        out_json({
            "ok": True,
            "matched": True,
            "source": "folder_cache",
            "subject_id": sid,
            "subject_name": saved.get("name"),
            "season": season or 1,
            "episode": episode,
            "episode_title": resolve_title(sid),
            "query": title,
        })
        return

    if not title:
        out_json({"ok": True, "matched": False, "season": season or 1, "episode": episode, "query": ""})
        return

    query = title
    if season and season > 1 and not re.search(r"第.{1,3}[季部期]|Season\s*\d", query, re.I):
        query_with_season = f"{title} 第{season}季"
    else:
        query_with_season = query

    items, err = search_subjects(query_with_season, token)
    if (err or not items) and query_with_season != query:
        items, err = search_subjects(query, token)

    if err or not items:
        out_json({"ok": True, "matched": False, "season": season or 1, "episode": episode, "query": title, "error": err or ""})
        return

    best = pick_best_subject(items, season)
    sid = best["id"]
    out_json({
        "ok": True,
        "matched": True,
        "source": "search",
        "subject_id": sid,
        "subject_name": best["name_cn"] or best["name"],
        "season": season or 1,
        "episode": episode,
        "episode_title": resolve_title(sid),
        "query": title,
    })


def cmd_mark(cfg_dir, subject_id, ep_num):
    auth = load_json(os.path.join(cfg_dir, "bangumi-auth.json"), {})
    token = auth.get("token")
    if not token:
        out_json({"ok": False, "error": "请先登录 Bangumi"})
        return

    sid = int(subject_id)
    found, err = get_episode_info(cfg_dir, sid, ep_num, token, allow_cache=True)
    if not found and err is None:
        # Refresh cache once in case new episode was added recently
        found, err = get_episode_info(cfg_dir, sid, ep_num, token, allow_cache=False)

    if err is not None:
        out_json({"ok": False, "error": f"获取剧集失败：{err}"})
        return
    if not found or not found.get("id"):
        out_json({"ok": False, "error": f"未找到第 {ep_num} 话"})
        return

    ep_id = found["id"]
    ep_title = extract_ep_title(found)

    # Ensure subject is in user's collection (3 = watching) if not collected yet
    col_status, _ = api_request("GET", f"/v0/users/{auth['user']['username']}/collections/{sid}", token=token)
    if col_status == 404:
        api_request("POST", f"/v0/users/-/collections/{sid}", token=token, body={"type": 3})

    # Mark episode watched (type=2)
    m_status, m_obj = api_request(
        "PUT",
        f"/v0/users/-/collections/-/episodes/{ep_id}",
        token=token,
        body={"type": 2},
    )
    if m_status < 200 or m_status >= 300:
        if m_status == 0:
            msg = "网络请求失败"
        elif m_status == 401:
            msg = "Token 已失效，请重新登录"
        else:
            msg = m_obj.get("description") or m_obj.get("message") or f"HTTP {m_status}"
        out_json({"ok": False, "error": msg})
        return

    out_json({
        "ok": True,
        "episode_id": ep_id,
        "episode_title": ep_title,
        "ep_num": ep_num,
    })


def main():
    if len(sys.argv) < 3:
        out_json({"ok": False, "error": "invalid args"})
        return
    cfg_dir = sys.argv[1]
    cmd = sys.argv[2]

    if cmd == "status":
        cmd_status(cfg_dir)
    elif cmd == "login" and len(sys.argv) >= 4:
        cmd_login(cfg_dir, sys.argv[3])
    elif cmd == "logout":
        cmd_logout(cfg_dir)
    elif cmd == "search" and len(sys.argv) >= 4:
        cmd_search(cfg_dir, sys.argv[3])
    elif cmd == "bind" and len(sys.argv) >= 6:
        ep_arg = sys.argv[6] if len(sys.argv) >= 7 else None
        fp_arg = sys.argv[7] if len(sys.argv) >= 8 else None
        cmd_bind_folder(cfg_dir, sys.argv[3], sys.argv[4], sys.argv[5], ep_arg, fp_arg)
    elif cmd == "match" and len(sys.argv) >= 4:
        hint = sys.argv[4] if len(sys.argv) >= 5 else ""
        cmd_match(cfg_dir, sys.argv[3], hint)
    elif cmd == "mark" and len(sys.argv) >= 5:
        cmd_mark(cfg_dir, sys.argv[3], sys.argv[4])
    else:
        out_json({"ok": False, "error": f"unknown command: {cmd}"})


if __name__ == "__main__":
    main()
