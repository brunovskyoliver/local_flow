//! The worker's `provision` progress lines on stderr: `specs/026-dictation-both-platforms`, R3.
//! `provision model=<id> state=downloading|verifying|verified|failed completed= total= reason=`

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Line {
    Progress { completed: u64, total: u64, verifying: bool },
    Verified,
    Failed(String),
}

pub fn parse(line: &str) -> Option<Line> {
    let mut words = line.split_whitespace();
    (words.next()? == "provision").then_some(())?;
    let field = |key: &str| line.split_whitespace().find_map(|w| w.strip_prefix(key)?.strip_prefix('='));
    let count = |key: &str| field(key).and_then(|n| n.parse().ok()).unwrap_or(0);
    match field("state")? {
        "downloading" => Some(Line::Progress { completed: count("completed"), total: count("total"), verifying: false }),
        "verifying" => Some(Line::Progress { completed: count("completed"), total: count("total"), verifying: true }),
        "verified" => Some(Line::Verified),
        "failed" => Some(Line::Failed(field("reason").unwrap_or("failed").to_string())),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_state_reads_and_other_lines_do_not() {
        assert_eq!(parse("provision model=m state=downloading completed=4 total=9"), Some(Line::Progress { completed: 4, total: 9, verifying: false }));
        assert_eq!(parse("provision model=m state=verifying completed=9 total=9"), Some(Line::Progress { completed: 9, total: 9, verifying: true }));
        assert_eq!(parse("provision model=m state=verified completed=9 total=9"), Some(Line::Verified));
        assert_eq!(parse("provision model=m state=failed reason=hash_mismatch"), Some(Line::Failed("hash_mismatch".into())));
        assert_eq!(parse("provision state=failed reason=meeting_unsupported"), Some(Line::Failed("meeting_unsupported".into())));
        assert_eq!(parse("state=ready"), None);
        assert_eq!(parse("provision model=m state=resting"), None);
    }
}
