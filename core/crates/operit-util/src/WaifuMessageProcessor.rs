use crate::ChatUtils::ChatUtils;
use crate::streamnative::NativeMarkdownSplitter::{MarkdownNodeStable, MarkdownProcessorType};
use fancy_regex::Regex as FancyRegex;
use regex::Regex;

/// Waifu-mode message processor.
///
/// Splits an AI reply into sentence chunks (by punctuation) so it can be sent
/// sentence-by-sentence, mimicking a "waifu" typing rhythm. Mirrors the Kotlin
/// `WaifuMessageProcessor` behavior, adapted to Rust.
#[derive(Debug, Clone, Default)]
pub struct WaifuMessageProcessor;

const ENTITY_PLACEHOLDER_PREFIX: &str = "{WAIFUENTITY:";
const ENTITY_PLACEHOLDER_SUFFIX: &str = "}";

// Fenced code blocks (closed or unclosed).
static FENCED_CODE_BLOCK_REGEX: &str = r"```[^\r\n`]*[\r\n]?[\s\S]*?```";
static UNCLOSED_FENCED_CODE_BLOCK_REGEX: &str = r"```[^\r\n`]*[\r\n]?[\s\S]*$";
// Sentence split: break after 。！？~～.!?… (with lookarounds to protect URLs/quotes).
// Uses r#"..."# so ASCII double-quotes inside the character class don't terminate the literal.
static SENTENCE_SPLIT_REGEX: &str =
    r#"(?<=[。！？~～])(?!['""”’」』])|(?<=[!?])(?!['""”’」』])|(?<=\.)(?![.\d""'”’」』])|(?<=\.)$|(?<=\.{3})|(?<=[…](?![…]))"#;
static SENTENCE_END_REGEX: &str = r"(?:[。！？~～.!?…]|\.{3})\s*$";
static HORIZONTAL_RULE_REGEX: &str = r"^[-_*]{3,}$";
static MARKDOWN_ENTITY_REGEX: &str = r"!?\[[^\]]*?\]\([^)]*?\)";
static BARE_URL_REGEX: &str = r"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+";
static EMAIL_ADDRESS_REGEX: &str = r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}";
static DOMAIN_URL_REGEX: &str =
    r"(?<![@\w])(?:www\.)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?::\d+)?(?:[/?#][A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?";
static ENTITY_PLACEHOLDER_REGEX: &str = r"\{WAIFUENTITY:\d+\}";

// Chars treated as trailing protected text (kept with the protected entity).
const TRAILING_PROTECTED_TEXT_CHARS: &[char] = &[
    '。', '！', '？', '.', '!', '?', '…', '，', ',', '；', ';', '：', ':', ')', '）', ']', '】', '}',
    '」', '"', '\'',
];

impl WaifuMessageProcessor {
    /// Splits a full message into sentences, restoring protected entities.
    pub fn split_message_by_sentences(content: &str, remove_punctuation: bool) -> Vec<String> {
        Self::split_message_by_sentences_internal(
            &Self::build_renderable_content_for_waifu(content),
            remove_punctuation,
            true,
        )
    }

    /// Splits into stable (complete) segments only, ignoring trailing incomplete tail.
    pub fn split_stable_message_segments(content: &str, remove_punctuation: bool) -> Vec<String> {
        Self::split_message_by_sentences_internal(
            &Self::build_renderable_content_for_waifu(content),
            remove_punctuation,
            false,
        )
    }

    /// Cleans content by stripping status/tool/markup tags and markdown markers.
    pub fn clean_content_for_waifu(content: &str) -> String {
        let sanitized = ChatUtils::remove_thinking_content(
            &ChatUtils::strip_gemini_thought_signature_meta(
                &Self::build_renderable_content_for_waifu(content),
            ),
        );

        let fenced = Regex::new(FENCED_CODE_BLOCK_REGEX).expect("fenced regex");
        let unclosed = Regex::new(UNCLOSED_FENCED_CODE_BLOCK_REGEX).expect("unclosed regex");
        let mut s = fenced.replace_all(&sanitized, " ").to_string();
        s = unclosed.replace_all(&s, " ").to_string();

        // Strip status / tool / tool_result / emotion tags.
        s = strip_tag_blocks(&s, "status");
        s = strip_tag_blocks(&s, "tool");
        s = strip_tag_blocks(&s, "tool_result");
        s = strip_tag_blocks(&s, "emotion");
        s = strip_tag_blocks(&s, "think");
        s = strip_tag_blocks(&s, "thinking");
        s = strip_tag_blocks(&s, "search");
        s = strip_tag_blocks(&s, "memory");

        // Markdown markers.
        s = Regex::new(r"!?\[(.*?)\]\(.*?\)").expect("md link").replace_all(&s, "$1").to_string();
        s = Regex::new(r"(?m)^#+\s*").expect("md h").replace_all(&s, "").to_string();
        s = Regex::new(r"(?m)^>\s*").expect("md quote").replace_all(&s, "").to_string();
        s = Regex::new(r"(?m)^[\*\-+]\s+").expect("md ul").replace_all(&s, "").to_string();
        s = Regex::new(r"(?m)^\d+\.\s+").expect("md ol").replace_all(&s, "").to_string();
        s = Regex::new(r"```[a-zA-Z]*\n?|\n?```").expect("md fence").replace_all(&s, "").to_string();
        // Bold-italic / bold / italic / strikethrough (avoid regex backreferences).
        s = Regex::new(r"\*\*\*(.+?)\*\*\*").expect("bi").replace_all(&s, "$1").to_string();
        s = Regex::new(r"___(.+?)___").expect("bi2").replace_all(&s, "$1").to_string();
        s = Regex::new(r"\*\*(.+?)\*\*").expect("b").replace_all(&s, "$1").to_string();
        s = Regex::new(r"__(.+?)__").expect("b2").replace_all(&s, "$1").to_string();
        s = Regex::new(r"\*(.+?)\*").expect("i").replace_all(&s, "$1").to_string();
        s = Regex::new(r"_(.+?)_").expect("i2").replace_all(&s, "$1").to_string();
        s = Regex::new(r"~~(.+?)~~").expect("del").replace_all(&s, "$1").to_string();
        // Inline code.
        s = Regex::new(r"`(.+?)`").expect("code").replace_all(&s, "$1").to_string();
        // Horizontal rule.
        s = Regex::new(r"(?m)^[-_*]{3,}\s*$").expect("hr").replace_all(&s, "").to_string();
        // Any remaining XML tag.
        s = Regex::new(r"<[^>]*>").expect("anyxml").replace_all(&s, "").to_string();
        // Collapse whitespace.
        s = Regex::new(r"\s+").expect("ws").replace_all(&s, " ").to_string();

        s.trim().to_string()
    }

    /// Removes the `<emotion>` tags, keeping their inner text (emoji assets are not available).
    pub fn process_emotion_tags_text(content: &str) -> String {
        let emotion_regex = Regex::new(r"<emotion>([^<]+)</emotion>").expect("emotion regex");
        emotion_regex
            .replace_all(content, |caps: &regex::Captures| caps[1].trim().to_string())
            .to_string()
    }

    /// Separates `<emotion>` blocks from surrounding text into distinct items.
    pub fn separate_emotion_and_text(content: &str) -> Vec<String> {
        if content.trim().is_empty() {
            return vec![content.to_string()];
        }
        let emotion_regex = Regex::new(r"<emotion>([^<]+)</emotion>").expect("emotion regex");
        let mut result = Vec::new();
        let mut last_end = 0;
        for m in emotion_regex.find_iter(content) {
            let before = content[last_end..m.start()].trim();
            if !before.is_empty() {
                result.push(before.to_string());
            }
            // Keep the raw tag as an item; image rendering is out of scope.
            result.push(m.as_str().to_string());
            last_end = m.end();
        }
        let after = content[last_end..].trim();
        if !after.is_empty() {
            result.push(after.to_string());
        }
        if result.is_empty() {
            result.push(content.to_string());
        }
        result
    }

    // ------- internal helpers -------

    fn split_message_by_sentences_internal(
        content: &str,
        remove_punctuation: bool,
        include_trailing_incomplete: bool,
    ) -> Vec<String> {
        if content.trim().is_empty() {
            return Vec::new();
        }

        let mut entities: Vec<String> = Vec::new();
        let mut content_with_placeholders = content.to_string();

        let markdown_entity_regex = Regex::new(MARKDOWN_ENTITY_REGEX).expect("md entity regex");
        content_with_placeholders = markdown_entity_regex
            .replace_all(&content_with_placeholders, |caps: &regex::Captures| {
                create_placeholder(caps[0].to_string(), &mut entities)
            })
            .to_string();

        content_with_placeholders =
            protect_matches(&content_with_placeholders, BARE_URL_REGEX, &mut entities);
        content_with_placeholders =
            protect_matches(&content_with_placeholders, EMAIL_ADDRESS_REGEX, &mut entities);
        content_with_placeholders =
            protect_matches(&content_with_placeholders, DOMAIN_URL_REGEX, &mut entities);

        let segments = split_into_segments(&content_with_placeholders);

        // Determine whether each segment has a following stable boundary.
        let mut has_following_stable_boundary = vec![false; segments.len()];
        {
            let mut seen_stable_boundary = false;
            for index in (0..segments.len()).rev() {
                has_following_stable_boundary[index] = seen_stable_boundary;
                if segment_produces_output(&segments[index])
                    && can_close_stable_text_at_block_boundary(segments[index].block_type)
                {
                    seen_stable_boundary = true;
                }
            }
        }

        let mut result_with_placeholders: Vec<String> = Vec::new();

        for (segment_index, segment) in segments.iter().enumerate() {
            if segment.is_protected {
                let block = segment.content.trim_matches(['\n', '\r']);
                if !block.trim().is_empty() {
                    result_with_placeholders.push(block.to_string());
                }
                continue;
            }

            let content_without_thinking = ChatUtils::remove_thinking_content(&segment.content);
            if content_without_thinking.trim().is_empty() {
                continue;
            }

            for item in Self::separate_emotion_and_text(&content_without_thinking) {
                // Emotion image item (starts with ![]) — keep as-is.
                if item.starts_with("![") {
                    result_with_placeholders.push(item);
                    continue;
                }

                let cleaned_content = Self::clean_content_for_waifu(&item);
                if cleaned_content.trim().is_empty() {
                    continue;
                }

                let mut sentences = Self::split_plain_text_into_sentences(
                    &cleaned_content,
                    remove_punctuation,
                );

                if Self::should_split_structured_markdown_lines(&item, &sentences) {
                    sentences = Self::split_structured_markdown_lines(&item, remove_punctuation);
                }

                if !include_trailing_incomplete && !sentences.is_empty() {
                    if let Some(start) = find_last_unclosed_inline_markdown_start(&item) {
                        let stable_raw_content = &item[..start];
                        let stable_cleaned_content =
                            Self::clean_content_for_waifu(stable_raw_content);
                        sentences = Self::split_stable_sentences_for_raw_content(
                            stable_raw_content,
                            &stable_cleaned_content,
                            remove_punctuation,
                            segment,
                            has_following_stable_boundary[segment_index],
                        );
                    } else if Self::should_hold_last_stable_sentence(
                        &item,
                        &cleaned_content,
                        segment,
                        has_following_stable_boundary[segment_index],
                    ) {
                        sentences.truncate(sentences.len().saturating_sub(1));
                    }
                }

                result_with_placeholders.extend(sentences);
            }
        }

        let merged = merge_punctuation_only_segments(&result_with_placeholders);

        // Restore placeholders.
        let placeholder_regex =
            Regex::new(r"\{WAIFUENTITY:(\d+)\}").expect("placeholder restore regex");
        merged
            .into_iter()
            .map(|sentence| {
                let mut current = sentence;
                while placeholder_regex.is_match(&current) {
                    let next = placeholder_regex
                        .replace_all(&current, |caps: &regex::Captures| {
                            let index: usize = caps[1].parse().unwrap_or(usize::MAX);
                            if index < entities.len() {
                                entities[index].clone()
                            } else {
                                caps[0].to_string()
                            }
                        })
                        .to_string();
                    if next == current {
                        break;
                    }
                    current = next;
                }
                current
            })
            .collect()
    }

    fn split_plain_text_into_sentences(cleaned_content: &str, remove_punctuation: bool) -> Vec<String> {
        if cleaned_content.trim().is_empty() {
            return Vec::new();
        }

        let split_regex = FancyRegex::new(SENTENCE_SPLIT_REGEX).expect("sentence split regex");
        let mut sentences = split_regex
            .split(cleaned_content)
            .filter_map(|r| r.ok())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>();

        if remove_punctuation {
            let punct_regex = Regex::new(r"[。！？.!?]+$").expect("punct regex");
            sentences = sentences
                .into_iter()
                .map(|sentence| {
                    if sentence.ends_with("...") {
                        sentence.trim().to_string()
                    } else {
                        punct_regex.replace_all(&sentence, "").trim().to_string()
                    }
                })
                .filter(|s| !s.is_empty())
                .collect();
        }

        sentences
    }

    fn should_split_structured_markdown_lines(content: &str, sentences: &[String]) -> bool {
        if sentences.len() != 1 {
            return false;
        }
        let non_empty_lines = content
            .lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>();
        if non_empty_lines.len() < 2 {
            return false;
        }
        non_empty_lines
            .iter()
            .any(|line| is_url_or_email_line(&clean_structured_markdown_line(line)))
    }

    fn split_structured_markdown_lines(content: &str, remove_punctuation: bool) -> Vec<String> {
        let mut results = Vec::new();
        for raw_line in content.lines() {
            let trimmed = raw_line.trim();
            if trimmed.is_empty()
                || Regex::new(HORIZONTAL_RULE_REGEX)
                    .expect("hr regex")
                    .is_match(trimmed)
            {
                continue;
            }
            let cleaned = clean_structured_markdown_line(trimmed);
            if cleaned.trim().is_empty() {
                continue;
            }
            let line_content = Self::clean_content_for_waifu(&cleaned);
            results.extend(Self::split_plain_text_into_sentences(
                &line_content,
                remove_punctuation,
            ));
        }
        merge_punctuation_only_segments(&results)
    }

    fn split_stable_sentences_for_raw_content(
        raw_content: &str,
        cleaned_content: &str,
        remove_punctuation: bool,
        segment: &Segment,
        has_following_stable_boundary: bool,
    ) -> Vec<String> {
        if cleaned_content.trim().is_empty() {
            return Vec::new();
        }
        let mut stable_sentences =
            Self::split_plain_text_into_sentences(cleaned_content, remove_punctuation);

        if Self::should_split_structured_markdown_lines(raw_content, &stable_sentences) {
            stable_sentences =
                Self::split_structured_markdown_lines(raw_content, remove_punctuation);
        }

        if !stable_sentences.is_empty()
            && Self::should_hold_last_stable_sentence(
                raw_content,
                cleaned_content,
                segment,
                has_following_stable_boundary,
            )
        {
            stable_sentences.truncate(stable_sentences.len().saturating_sub(1));
        }

        stable_sentences
    }

    fn should_hold_last_stable_sentence(
        raw_content: &str,
        cleaned_content: &str,
        segment: &Segment,
        has_following_stable_boundary: bool,
    ) -> bool {
        !has_stable_sentence_ending(cleaned_content)
            && !line_allows_stable_without_sentence_ending(&get_last_visible_line(raw_content))
            && !segment.can_use_block_boundary_as_stable_ending(has_following_stable_boundary)
    }

    /// Extracts the plain-text rendering: keeps TEXT blocks, drops XML blocks.
    pub fn build_renderable_content_for_waifu(content: &str) -> String {
        if content.trim().is_empty() {
            return String::new();
        }
        use crate::StructuredAssistantContentParser::{BlockKind, StructuredAssistantContentParser};
        let blocks = StructuredAssistantContentParser::parse(content);
        if blocks.is_empty() {
            return content.to_string();
        }
        let mut builder = String::new();
        for block in blocks {
            match block.kind {
                BlockKind::Text => builder.push_str(&block.raw_content),
                BlockKind::Xml => {}
            }
        }
        builder
    }
}

/// Streaming session state: tracks emitted segments and returns only new stable ones.
#[derive(Debug, Default)]
pub struct StreamingSession {
    emitted_segments: Vec<String>,
    remove_punctuation: bool,
}

impl StreamingSession {
    pub fn new(remove_punctuation: bool) -> Self {
        Self {
            emitted_segments: Vec::new(),
            remove_punctuation,
        }
    }

    /// Returns newly stabilized segments from the current buffered content.
    pub fn collect_stable_segments(&mut self, content: &str) -> Vec<String> {
        let segments = WaifuMessageProcessor::split_message_by_sentences_internal(
            &WaifuMessageProcessor::build_renderable_content_for_waifu(content),
            self.remove_punctuation,
            false,
        );
        self.collect_segments(segments)
    }

    /// Returns all final segments (including trailing incomplete) at stream end.
    pub fn collect_final_segments(&mut self, content: &str) -> Vec<String> {
        let segments = WaifuMessageProcessor::split_message_by_sentences_internal(
            &WaifuMessageProcessor::build_renderable_content_for_waifu(content),
            self.remove_punctuation,
            true,
        );
        self.collect_segments(segments)
    }

    fn collect_segments(&mut self, segments: Vec<String>) -> Vec<String> {
        if segments.is_empty() {
            return Vec::new();
        }
        if segments.len() < self.emitted_segments.len() {
            return Vec::new();
        }
        // Prefix must match everything already emitted.
        if self
            .emitted_segments
            .iter()
            .zip(segments.iter())
            .any(|(a, b)| a != b)
        {
            return Vec::new();
        }
        let new_segments = segments
            .iter()
            .skip(self.emitted_segments.len())
            .cloned()
            .collect::<Vec<_>>();
        self.emitted_segments.extend(new_segments.iter().cloned());
        new_segments
    }
}

// ---------- free helpers ----------

#[derive(Debug, Clone)]
struct Segment {
    content: String,
    is_protected: bool,
    block_type: MarkdownProcessorType,
}

impl Segment {
    fn can_use_block_boundary_as_stable_ending(&self, has_following_stable_boundary: bool) -> bool {
        has_following_stable_boundary || can_close_stable_text_at_block_boundary(self.block_type)
    }
}

fn create_placeholder(value: String, entities: &mut Vec<String>) -> String {
    let placeholder = format!("{ENTITY_PLACEHOLDER_PREFIX}{}{ENTITY_PLACEHOLDER_SUFFIX}", entities.len());
    entities.push(value);
    placeholder
}

fn protect_matches(source: &str, pattern: &str, entities: &mut Vec<String>) -> String {
    let regex = FancyRegex::new(pattern).expect("protect regex");
    regex
        .replace_all(source, |caps: &fancy_regex::Captures| {
            let matched = caps.get(0).map(|m| m.as_str()).unwrap_or("");
            let (protected_value, trailing) = split_trailing_protected_text(matched.trim());
            if protected_value.is_empty() {
                matched.to_string()
            } else {
                create_placeholder(protected_value, entities) + &trailing
            }
        })
        .into_owned()
}

fn split_trailing_protected_text(value: &str) -> (String, String) {
    if value.is_empty() {
        return (String::new(), String::new());
    }
    let chars = value.char_indices().collect::<Vec<_>>();
    let mut split_index = value.len();
    // Find the byte index of the first trailing protected char scanning from the end.
    for &(idx, ch) in chars.iter().rev() {
        if TRAILING_PROTECTED_TEXT_CHARS.contains(&ch) {
            split_index = idx;
        } else {
            break;
        }
    }
    if split_index >= value.len() {
        return (value.to_string(), String::new());
    }
    (value[..split_index].to_string(), value[split_index..].to_string())
}

fn split_into_segments(content: &str) -> Vec<Segment> {
    if content.is_empty() {
        return vec![Segment {
            content: String::new(),
            is_protected: false,
            block_type: MarkdownProcessorType::PlainText,
        }];
    }

    use crate::streamnative::NativeMarkdownStreamOperators::NativeMarkdownStreamOperators;
    let nodes: Vec<MarkdownNodeStable> = content.nativeMarkdownSplitByBlock();

    let mut segments = Vec::new();
    for node in nodes {
        if node.content.is_empty() {
            continue;
        }
        let is_protected = matches!(
            node.r#type,
            MarkdownProcessorType::CodeBlock | MarkdownProcessorType::Table
        );
        segments.push(Segment {
            content: node.content.clone(),
            is_protected,
            block_type: node.r#type,
        });
    }
    segments
}

fn segment_produces_output(segment: &Segment) -> bool {
    if segment.is_protected {
        return !segment.content.trim_matches(['\n', '\r']).trim().is_empty();
    }
    let content_without_thinking = ChatUtils::remove_thinking_content(&segment.content);
    if content_without_thinking.trim().is_empty() {
        return false;
    }
    WaifuMessageProcessor::separate_emotion_and_text(&content_without_thinking).iter().any(|item| {
        item.starts_with("![") || !WaifuMessageProcessor::clean_content_for_waifu(item).trim().is_empty()
    })
}

fn can_close_stable_text_at_block_boundary(block_type: MarkdownProcessorType) -> bool {
    matches!(
        block_type,
        MarkdownProcessorType::Header
            | MarkdownProcessorType::BlockQuote
            | MarkdownProcessorType::CodeBlock
            | MarkdownProcessorType::OrderedList
            | MarkdownProcessorType::UnorderedList
            | MarkdownProcessorType::BlockLatex
            | MarkdownProcessorType::Table
            | MarkdownProcessorType::Image
    )
}

fn merge_punctuation_only_segments(segments: &[String]) -> Vec<String> {
    if segments.is_empty() {
        return Vec::new();
    }
    let punct_regex = Regex::new(r"^[。！？~～.!?…]+$").expect("punct only regex");
    let mut merged: Vec<String> = vec![segments[0].clone()];
    for current in segments.iter().skip(1) {
        let trimmed = current.trim();
        if !trimmed.is_empty() && punct_regex.is_match(trimmed) {
            let last_index = merged.len() - 1;
            let last = &merged[last_index];
            if !last.contains('\n') && !last.contains('\r') {
                merged[last_index] = format!("{last}{current}");
            } else {
                merged.push(current.clone());
            }
        } else {
            merged.push(current.clone());
        }
    }
    merged
}

fn clean_structured_markdown_line(line: &str) -> String {
    let mut s = line.trim().to_string();
    let replacements = [
        (r"^#+\s*", ""),
        (r"^>\s*", ""),
        (r"^(?:[\-*+]\s+|\d+\.\s+)", ""),
        (r"^\*\*(.+)\*\*$", "$1"),
        (r"^__(.+)__$", "$1"),
        (r"^~~(.+)~~$", "$1"),
    ];
    for (pat, rep) in replacements {
        s = Regex::new(pat).expect("clean md line").replace_all(&s, rep).to_string();
    }
    s.trim().to_string()
}

fn get_last_visible_line(content: &str) -> String {
    content
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .last()
        .unwrap_or("")
        .to_string()
}

fn line_allows_stable_without_sentence_ending(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    if trimmed.starts_with("```")
        || trimmed.starts_with('|')
        || trimmed.starts_with("$$")
        || Regex::new(r"^(?:#+\s*|>\s*|[-*+]\s+|\d+\.\s+)")
            .expect("line allow regex")
            .is_match(trimmed)
    {
        return true;
    }
    is_url_or_email_line(&clean_structured_markdown_line(trimmed))
}

fn is_url_or_email_line(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    Regex::new(BARE_URL_REGEX).expect("url regex").is_match(trimmed)
        || FancyRegex::new(DOMAIN_URL_REGEX)
            .expect("domain regex")
            .is_match(trimmed)
            .unwrap_or(false)
        || Regex::new(EMAIL_ADDRESS_REGEX).expect("email regex").is_match(trimmed)
        || Regex::new(ENTITY_PLACEHOLDER_REGEX).expect("entity regex").is_match(trimmed)
}

fn has_stable_sentence_ending(content: &str) -> bool {
    Regex::new(SENTENCE_END_REGEX)
        .expect("sentence end regex")
        .is_match(content.trim_end())
}

fn find_last_unclosed_inline_markdown_start(content: &str) -> Option<usize> {
    let trimmed = content.trim_end();
    if trimmed.is_empty() {
        return None;
    }
    ["**", "__", "~~", "`"]
        .iter()
        .filter_map(|delimiter| find_last_unclosed_delimiter_start(trimmed, delimiter))
        .max()
}

fn find_last_unclosed_delimiter_start(content: &str, delimiter: &str) -> Option<usize> {
    let mut starts = Vec::new();
    let mut index = 0;
    while index + delimiter.len() <= content.len() {
        let relative = content[index..].find(delimiter)?;
        let found_index = index + relative;
        if !is_escaped(content, found_index) {
            starts.push(found_index);
        }
        index = found_index + delimiter.len();
    }
    if starts.len() % 2 == 0 {
        return None;
    }
    starts.last().copied()
}

fn is_escaped(content: &str, index: usize) -> bool {
    let mut slash_count = 0;
    let mut cursor = index;
    while cursor > 0 {
        let prev = content[..cursor].chars().next_back();
        match prev {
            Some('\\') => {
                slash_count += 1;
                cursor -= 1;
            }
            _ => break,
        }
    }
    slash_count % 2 == 1
}

fn strip_tag_blocks(content: &str, tag_name: &str) -> String {
    let open_pattern = format!(r"<{tag_name}\b[\s\S]*?</{tag_name}>");
    let closed = Regex::new(&open_pattern).expect("tag block regex");
    let without_closed = closed.replace_all(content, "");
    let self_closing_pattern = format!(r"<{tag_name}\b[^>]*/>");
    let self_closing = Regex::new(&self_closing_pattern).expect("self closing regex");
    self_closing.replace_all(&without_closed, "").to_string()
}

#[cfg(test)]
mod tests {
    use super::StreamingSession;
    use super::WaifuMessageProcessor;

    #[test]
    fn splits_chinese_sentences() {
        let out = WaifuMessageProcessor::split_message_by_sentences("你好。世界！你好吗？", false);
        assert_eq!(out, vec!["你好。", "世界！", "你好吗？"]);
    }

    #[test]
    fn splits_english_sentences() {
        let out = WaifuMessageProcessor::split_message_by_sentences("Hello. World! How are you?", false);
        assert_eq!(out, vec!["Hello.", "World!", "How are you?"]);
    }

    #[test]
    fn protects_url_from_splitting() {
        // "Visit https://example.com now." should not split inside the URL.
        let out = WaifuMessageProcessor::split_message_by_sentences(
            "Visit https://example.com/path?q=1.2 now. Done.",
            false,
        );
        assert_eq!(out, vec!["Visit https://example.com/path?q=1.2 now.", "Done."]);
    }

    #[test]
    fn protects_email_from_splitting() {
        let out = WaifuMessageProcessor::split_message_by_sentences("Email me at a.b@example.com. Ok?", false);
        assert_eq!(out, vec!["Email me at a.b@example.com.", "Ok?"]);
    }

    #[test]
    fn strips_markdown_markers() {
        let cleaned = WaifuMessageProcessor::clean_content_for_waifu("**bold** and *italic* and `code`");
        assert_eq!(cleaned, "bold and italic and code");
    }

    #[test]
    fn strips_think_and_status_tags() {
        let cleaned = WaifuMessageProcessor::clean_content_for_waifu(
            "<think>hidden</think><status type=\"x\">s</status>visible",
        );
        assert_eq!(cleaned, "visible");
    }

    #[test]
    fn merges_punctuation_only_segments() {
        let out = WaifuMessageProcessor::split_message_by_sentences("你好。！", false);
        assert_eq!(out, vec!["你好。！"]);
    }

    #[test]
    fn empty_input_returns_empty() {
        let out = WaifuMessageProcessor::split_message_by_sentences("", false);
        assert!(out.is_empty());
        let out = WaifuMessageProcessor::split_message_by_sentences("   ", false);
        assert!(out.is_empty());
    }

    #[test]
    fn remove_punctuation_flag() {
        let out = WaifuMessageProcessor::split_message_by_sentences("你好。世界。", true);
        assert_eq!(out, vec!["你好", "世界"]);
    }

    #[test]
    fn streaming_session_emits_new_stable_segments_only() {
        let mut session = StreamingSession::new(false);
        // First chunk has a complete first sentence.
        let first = session.collect_stable_segments("你好。世界");
        assert_eq!(first, vec!["你好。"]);
        // Second chunk completes the second sentence; only the new one should emit.
        let second = session.collect_stable_segments("你好。世界还在继续。");
        assert_eq!(second, vec!["世界还在继续。"]);
    }

    #[test]
    fn separate_emotion_tags_as_items() {
        let items = WaifuMessageProcessor::separate_emotion_and_text("开心<emotion>happy</emotion>结束");
        assert!(items.len() >= 2);
    }

    #[test]
    fn structured_markdown_lines_split() {
        let out = WaifuMessageProcessor::split_message_by_sentences(
            "## Title\nVisit https://a.com\nLine with url",
            false,
        );
        assert!(!out.is_empty());
    }
}
