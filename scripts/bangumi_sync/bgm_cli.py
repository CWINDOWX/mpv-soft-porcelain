import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "mpv-lazy-bangumi-sync/1.0 (https://github.com/bangumi/api)"
API_BASE = "https://api.bgm.tv"


def out_json(obj):
    sys.stdout.buffer.write((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, type(default)) else default
    except Exception:
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


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


def cmd_bind_folder(cfg_dir, folder_key, subject_id, subject_name):
    mp = os.path.join(cfg_dir, "bangumi-map.json")
    mapping = load_json(mp, {})
    norm_key = os.path.normpath(folder_key).lower()
    mapping[norm_key] = {"id": int(subject_id), "name": subject_name}
    save_json(mp, mapping)
    out_json({"ok": True})


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
    folder_key = os.path.normpath(os.path.dirname(filepath)).lower()
    mapping = load_json(os.path.join(cfg_dir, "bangumi-map.json"), {})

    title, season, episode = parse_episode_and_title(filepath, hint_anime)

    if folder_key in mapping:
        saved = mapping[folder_key]
        out_json({
            "ok": True,
            "matched": True,
            "source": "folder_cache",
            "subject_id": saved.get("id"),
            "subject_name": saved.get("name"),
            "season": season or 1,
            "episode": episode,
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

    items, err = search_subjects(query_with_season, auth.get("token"))
    if (err or not items) and query_with_season != query:
        items, err = search_subjects(query, auth.get("token"))

    if err or not items:
        out_json({"ok": True, "matched": False, "season": season or 1, "episode": episode, "query": title, "error": err or ""})
        return

    best = pick_best_subject(items, season)
    out_json({
        "ok": True,
        "matched": True,
        "source": "search",
        "subject_id": best["id"],
        "subject_name": best["name_cn"] or best["name"],
        "season": season or 1,
        "episode": episode,
        "query": title,
    })


def cmd_mark(cfg_dir, subject_id, ep_num):
    auth = load_json(os.path.join(cfg_dir, "bangumi-auth.json"), {})
    token = auth.get("token")
    if not token:
        out_json({"ok": False, "error": "尚未登录 Bangumi，请先在菜单中粘贴 Access Token 登录"})
        return

    sid = int(subject_id)
    target_ep = float(ep_num)

    # An exact ep on any page takes precedence over a sort match.
    found = None
    sort_match = None
    offset = 0
    while True:
        status, obj = api_request(
            "GET",
            "/v0/episodes",
            token=token,
            query={"subject_id": sid, "type": 0, "limit": 100, "offset": offset},
        )
        if status < 200 or status >= 300:
            msg = obj.get("description") or obj.get("message") or f"HTTP {status}"
            out_json({"ok": False, "error": f"获取剧集列表失败：{msg}"})
            return
        batch = obj.get("data") or []
        for ep in batch:
            if ep.get("ep") is not None and abs(float(ep["ep"]) - target_ep) < 1e-6:
                found = ep
                break
            if sort_match is None and ep.get("sort") is not None and abs(float(ep["sort"]) - target_ep) < 1e-6:
                sort_match = ep

        offset += len(batch)
        total = obj.get("total")
        if found or not batch or (total is not None and offset >= int(total)):
            break

    if found is None:
        found = sort_match
    if not found:
        out_json({"ok": False, "error": f"未在 Bangumi 条目 #{sid} 中找到第 {ep_num} 集"})
        return

    ep_id = found["id"]
    ep_title = found.get("name_cn") or found.get("name") or f"第 {ep_num} 集"

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
        msg = m_obj.get("description") or m_obj.get("message") or f"HTTP {m_status}"
        if m_status == 401:
            msg = "Bangumi Token 已失效，请重新登录"
        out_json({"ok": False, "error": f"标记已看失败：{msg}"})
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
        cmd_bind_folder(cfg_dir, sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == "match" and len(sys.argv) >= 4:
        hint = sys.argv[4] if len(sys.argv) >= 5 else ""
        cmd_match(cfg_dir, sys.argv[3], hint)
    elif cmd == "mark" and len(sys.argv) >= 5:
        cmd_mark(cfg_dir, sys.argv[3], sys.argv[4])
    else:
        out_json({"ok": False, "error": f"unknown command: {cmd}"})


if __name__ == "__main__":
    main()
