use crate::ChatMarkupRegex::ChatMarkupRegex;
use crate::streamnative::NativeXmlSplitter::NativeXmlSplitter;

/// Block kind classification for assistant-visible content.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum BlockKind {
    Text,
    Xml,
}

/// A parsed content block (either plain text or an XML-like tag).
#[derive(Debug, Clone, PartialEq)]
pub struct Block {
    pub kind: BlockKind,
    pub raw_content: String,
    pub content: String,
    pub tag_name: Option<String>,
    pub raw_tag_name: Option<String>,
    pub attrs: std::collections::HashMap<String, String>,
    pub closed: bool,
}

/// Parser that splits assistant content into plain-text and XML-like blocks.
pub struct StructuredAssistantContentParser;

impl StructuredAssistantContentParser {
    /// Parses content into a list of text/XML blocks, mirroring the Kotlin version.
    pub fn parse(content: &str) -> Vec<Block> {
        if content.is_empty() {
            return Vec::new();
        }

        let split_segments = NativeXmlSplitter::split_xml_tag(content);
        if split_segments.is_empty() {
            return vec![Block {
                kind: BlockKind::Text,
                raw_content: content.to_string(),
                content: content.to_string(),
                tag_name: None,
                raw_tag_name: None,
                attrs: std::collections::HashMap::new(),
                closed: true,
            }];
        }

        split_segments
            .into_iter()
            .filter_map(|segment| build_block(segment))
            .collect()
    }
}

fn build_block(segment: Vec<String>) -> Option<Block> {
    let kind = segment.first()?;
    let raw_content = segment.get(1).cloned().unwrap_or_default();
    if raw_content.is_empty() {
        return None;
    }

    if kind == "text" {
        return Some(Block {
            kind: BlockKind::Text,
            raw_content: raw_content.clone(),
            content: raw_content,
            tag_name: None,
            raw_tag_name: None,
            attrs: std::collections::HashMap::new(),
            closed: true,
        });
    }

    let raw_tag_name = ChatMarkupRegex::extract_opening_tag_name(&raw_content);
    let tag_name = ChatMarkupRegex::normalize_tool_like_tag_name(raw_tag_name.as_deref())
        .or_else(|| raw_tag_name.clone());
    let closed = is_xml_fully_closed(&raw_content, raw_tag_name.as_deref());

    Some(Block {
        kind: BlockKind::Xml,
        raw_content: raw_content.clone(),
        content: extract_xml_inner_content(
            &raw_content,
            raw_tag_name.as_deref(),
            tag_name.as_deref(),
        ),
        tag_name,
        raw_tag_name: raw_tag_name.clone(),
        attrs: extract_xml_attributes(&raw_content),
        closed,
    })
}

fn extract_xml_inner_content(xml: &str, raw_tag_name: Option<&str>, normalized_tag_name: Option<&str>) -> String {
    let effective_tag_name = match (raw_tag_name, normalized_tag_name) {
        (Some(name), _) if !name.is_empty() => name.to_string(),
        (_, Some(name)) if !name.is_empty() => name.to_string(),
        _ => return xml.to_string(),
    };

    let start_tag = format!("<{effective_tag_name}");
    let Some(start_tag_index) = xml.find(&start_tag) else {
        return xml.to_string();
    };

    let Some(start_tag_end_relative) = xml[start_tag_index..].find('>') else {
        return xml.to_string();
    };
    let start_tag_end = start_tag_index + start_tag_end_relative;

    let end_tag = format!("</{effective_tag_name}>");
    let end_index = xml.rfind(&end_tag);
    let content_end_exclusive = match end_index {
        Some(end_index) if end_index > start_tag_end => end_index,
        _ => xml.len(),
    };

    xml[start_tag_end + 1..content_end_exclusive].to_string()
}

fn extract_xml_attributes(xml: &str) -> std::collections::HashMap<String, String> {
    let trimmed = xml.trim();
    let Some(start_tag_end) = trimmed.find('>') else {
        return std::collections::HashMap::new();
    };
    if start_tag_end == 0 {
        return std::collections::HashMap::new();
    }

    let start_tag = &trimmed[..start_tag_end + 1];
    parse_attributes(start_tag)
}

fn parse_attributes(start_tag: &str) -> std::collections::HashMap<String, String> {
    let mut attrs = std::collections::HashMap::new();
    let mut index = 0;
    let bytes = start_tag.as_bytes();
    let len = bytes.len();
    while index < len {
        // Skip whitespace and '<'.
        while index < len && (bytes[index].is_ascii_whitespace() || bytes[index] == b'<') {
            index += 1;
        }
        if index >= len {
            break;
        }
        // Parse attribute name.
        let name_start = index;
        while index < len
            && (bytes[index].is_ascii_alphanumeric()
                || bytes[index] == b'_'
                || bytes[index] == b'-'
                || bytes[index] == b':')
        {
            index += 1;
        }
        if index == name_start {
            index += 1;
            continue;
        }
        let name = start_tag[name_start..index].to_string();
        // Skip whitespace before '='.
        while index < len && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        if index >= len || bytes[index] != b'=' {
            continue;
        }
        index += 1;
        // Skip whitespace after '='.
        while index < len && bytes[index].is_ascii_whitespace() {
            index += 1;
        }
        if index >= len || (bytes[index] != b'"' && bytes[index] != b'\'') {
            continue;
        }
        let quote = bytes[index];
        index += 1;
        let value_start = index;
        while index < len && bytes[index] != quote {
            index += 1;
        }
        if index >= len {
            break;
        }
        let value = start_tag[value_start..index].to_string();
        index += 1;
        if !name.is_empty() {
            attrs.insert(name, value);
        }
    }
    attrs
}

fn is_xml_fully_closed(xml: &str, raw_tag_name: Option<&str>) -> bool {
    let trimmed = xml.trim();
    if trimmed.ends_with("/>") {
        return true;
    }

    let effective_tag_name = raw_tag_name
        .filter(|name| !name.is_empty())
        .map(|name| name.to_string())
        .or_else(|| ChatMarkupRegex::extract_opening_tag_name(trimmed));

    match effective_tag_name {
        Some(name) => trimmed.contains(&format!("</{name}>")),
        None => false,
    }
}
