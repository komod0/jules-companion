/**
 * @file markdown_rendering_test.cpp
 * @brief Unit tests for markdown rendering in SessionDetailWidget
 *
 * Tests the markdownToHtml conversion by exercising the widget's public
 * interface: setting sessions with markdown content in activities and
 * verifying the rendered output through activityCount() and the widget's state.
 *
 * Since markdownToHtml is private, we test it indirectly through
 * SessionDetailWidget::setSession() with activities containing markdown text.
 * We also verify the formatting by inspecting the widget hierarchy.
 */

#include <gtest/gtest.h>
#include <QApplication>
#include <QLabel>

#include "ui/session_detail_widget.h"
#include "api/jules_api_client.h"

namespace jules {
namespace test {

class MarkdownRenderingTest : public ::testing::Test {
protected:
    Session createSessionWithAgentMessage(const QString& message) {
        Session session;
        session.id = "md-test";
        session.name = "sessions/md-test";
        session.prompt = "Test";
        session.state = SessionState::Completed;
        session.createTime = "2026-01-01T00:00:00Z";
        session.updateTime = session.createTime;

        Activity activity;
        activity.id = "act-md";
        activity.name = "activities/act-md";
        activity.originator = "AGENT";
        AgentMessaged agentMsg;
        agentMsg.agentMessage = message;
        activity.agentMessaged = agentMsg;

        session.activities = QList<Activity>{activity};
        return session;
    }

    // Find all QLabel widgets in the widget tree that contain rich text
    QList<QLabel*> findBubbleLabels(QWidget* parent) {
        QList<QLabel*> result;
        for (auto* label : parent->findChildren<QLabel*>()) {
            if (label->textFormat() == Qt::RichText) {
                result.append(label);
            }
        }
        return result;
    }

    // Find the agent bubble label text (the last rich-text label)
    QString getAgentBubbleHtml(SessionDetailWidget& widget) {
        auto labels = findBubbleLabels(&widget);
        // The last rich-text label should be the agent message bubble
        // (prompt bubble comes first, then agent bubble)
        for (int i = labels.size() - 1; i >= 0; --i) {
            QString text = labels[i]->text();
            // Skip the prompt bubble (it will contain "Test")
            if (!text.contains(">Test<") && text.length() > 10) {
                return text;
            }
        }
        return QString();
    }
};

// Headers are rendered as h1/h2/h3 HTML tags
TEST_F(MarkdownRenderingTest, HeadersAreRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("# Heading 1\n## Heading 2\n### Heading 3"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<h1")) << "Missing h1 tag in: " << html.toStdString();
    EXPECT_TRUE(html.contains("Heading 1")) << "Missing h1 text in: " << html.toStdString();
    EXPECT_TRUE(html.contains("<h2")) << "Missing h2 tag in: " << html.toStdString();
    EXPECT_TRUE(html.contains("Heading 2")) << "Missing h2 text in: " << html.toStdString();
    EXPECT_TRUE(html.contains("<h3")) << "Missing h3 tag in: " << html.toStdString();
    EXPECT_TRUE(html.contains("Heading 3")) << "Missing h3 text in: " << html.toStdString();
}

// Bold text is rendered with <b> tags
TEST_F(MarkdownRenderingTest, BoldTextIsRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("This is **bold text** here"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<b>bold text</b>")) << "Missing bold in: " << html.toStdString();
}

// Italic text is rendered with <i> tags
TEST_F(MarkdownRenderingTest, ItalicTextIsRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("This is *italic text* here"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<i>italic text</i>")) << "Missing italic in: " << html.toStdString();
}

// Code blocks are rendered with <pre> tags
TEST_F(MarkdownRenderingTest, CodeBlocksAreRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("```\nint x = 42;\nreturn x;\n```"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<pre")) << "Missing pre tag in: " << html.toStdString();
    EXPECT_TRUE(html.contains("int x = 42;")) << "Missing code content in: " << html.toStdString();
}

// Inline code is rendered with <code> tags
TEST_F(MarkdownRenderingTest, InlineCodeIsRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("Use `printf()` to print"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<code")) << "Missing code tag in: " << html.toStdString();
    EXPECT_TRUE(html.contains("printf()")) << "Missing inline code text in: " << html.toStdString();
}

// Links are rendered as <a> tags
TEST_F(MarkdownRenderingTest, LinksAreRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("Visit [Example](https://example.com) now"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<a href")) << "Missing link tag in: " << html.toStdString();
    EXPECT_TRUE(html.contains("https://example.com")) << "Missing URL in: " << html.toStdString();
    EXPECT_TRUE(html.contains("Example")) << "Missing link text in: " << html.toStdString();
}

// Bullet lists are rendered with <li> tags
TEST_F(MarkdownRenderingTest, BulletListsAreRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("- Item one\n- Item two\n- Item three"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<li")) << "Missing li tag in: " << html.toStdString();
    EXPECT_TRUE(html.contains("Item one")) << "Missing item text in: " << html.toStdString();
    EXPECT_TRUE(html.contains("Item two")) << "Missing item text in: " << html.toStdString();
}

// Numbered lists are rendered with <li> tags
TEST_F(MarkdownRenderingTest, NumberedListsAreRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("1. First\n2. Second\n3. Third"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<li")) << "Missing li tag in: " << html.toStdString();
    EXPECT_TRUE(html.contains("First")) << "Missing numbered item in: " << html.toStdString();
    EXPECT_TRUE(html.contains("Second")) << "Missing numbered item in: " << html.toStdString();
}

// Blockquotes are rendered with <blockquote> tags
TEST_F(MarkdownRenderingTest, BlockquotesAreRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("> This is a quote"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<blockquote")) << "Missing blockquote tag in: " << html.toStdString();
    EXPECT_TRUE(html.contains("This is a quote")) << "Missing quote text in: " << html.toStdString();
}

// Horizontal rules are rendered with <hr> tags
TEST_F(MarkdownRenderingTest, HorizontalRulesAreRendered) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("Above\n---\nBelow"));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<hr")) << "Missing hr tag in: " << html.toStdString();
}

// Combined markdown renders correctly together
// Note: text must stay under 5 newlines and 225 chars to avoid truncation
TEST_F(MarkdownRenderingTest, CombinedMarkdownRendersCorrectly) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    // Keep to 4 newlines (5 lines) to avoid truncation threshold
    QString markdown =
        "# Summary\n"
        "Fixed the **critical** bug in `auth.py`.\n"
        "- Updated login flow\n"
        "> Note: requires testing";

    widget.setSession(createSessionWithAgentMessage(markdown));

    QString html = getAgentBubbleHtml(widget);
    EXPECT_TRUE(html.contains("<h1")) << "Missing h1 in combined: " << html.toStdString();
    EXPECT_TRUE(html.contains("<b>critical</b>")) << "Missing bold in combined: " << html.toStdString();
    EXPECT_TRUE(html.contains("<code")) << "Missing code in combined: " << html.toStdString();
    EXPECT_TRUE(html.contains("<li")) << "Missing list in combined: " << html.toStdString();
    EXPECT_TRUE(html.contains("<blockquote")) << "Missing blockquote in combined: " << html.toStdString();
}

// Activity count includes prompt bubble + agent message
TEST_F(MarkdownRenderingTest, ActivityCountIsCorrectWithMarkdown) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    widget.setSession(createSessionWithAgentMessage("# Hello\nWorld"));

    // 1 prompt bubble + 1 agent activity = 2
    EXPECT_EQ(widget.activityCount(), 2);
}

// Empty markdown produces no crash
TEST_F(MarkdownRenderingTest, EmptyMarkdownDoesNotCrash) {
    SessionDetailWidget widget;
    widget.resize(800, 600);

    Session session;
    session.id = "empty-md";
    session.name = "sessions/empty-md";
    session.prompt = "Test";
    session.state = SessionState::Completed;
    session.createTime = "2026-01-01T00:00:00Z";

    Activity activity;
    activity.id = "act-empty";
    activity.name = "activities/act-empty";
    activity.originator = "AGENT";
    AgentMessaged agentMsg;
    agentMsg.agentMessage = "";
    activity.agentMessaged = agentMsg;

    session.activities = QList<Activity>{activity};
    widget.setSession(session);

    // Should not crash; empty agent message produces no bubble
    // 1 prompt bubble only (empty agent text is skipped)
    EXPECT_EQ(widget.activityCount(), 1);
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QCoreApplication::setOrganizationName("JulesLinuxTest");
    QCoreApplication::setApplicationName("MarkdownRenderingTest");
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
