#include <gtest/gtest.h>
#include <QApplication>
#include <QSignalSpy>
#include <QPushButton>
#include <QDialogButtonBox>

#include "ui/feedback_dialog.h"

namespace jules {
namespace test {

class FeedbackDialogTest : public ::testing::Test {
protected:
};

TEST_F(FeedbackDialogTest, CanCreate) {
    FeedbackDialog dialog;
    EXPECT_FALSE(dialog.isValid());
}

TEST_F(FeedbackDialogTest, HasWindowTitle) {
    FeedbackDialog dialog;
    EXPECT_FALSE(dialog.windowTitle().isEmpty());
}

TEST_F(FeedbackDialogTest, DefaultTypeIsNotEmpty) {
    FeedbackDialog dialog;
    EXPECT_FALSE(dialog.feedbackType().isEmpty());
}

TEST_F(FeedbackDialogTest, EmptyTextIsInvalid) {
    FeedbackDialog dialog;
    EXPECT_TRUE(dialog.feedbackText().isEmpty());
    EXPECT_FALSE(dialog.isValid());
}

TEST_F(FeedbackDialogTest, EmptyEmailIsAcceptable) {
    FeedbackDialog dialog;
    EXPECT_TRUE(dialog.email().isEmpty());
}

TEST_F(FeedbackDialogTest, FeedbackSubmittedSignalIsValid) {
    FeedbackDialog dialog;
    QSignalSpy spy(&dialog, &FeedbackDialog::feedbackSubmitted);
    EXPECT_TRUE(spy.isValid());
}

TEST_F(FeedbackDialogTest, AcceptWithEmptyTextDoesNotEmitSignal) {
    FeedbackDialog dialog;
    QSignalSpy spy(&dialog, &FeedbackDialog::feedbackSubmitted);
    ASSERT_TRUE(spy.isValid());

    // Calling accept with empty text should be a no-op
    dialog.accept();
    EXPECT_EQ(spy.count(), 0);
}

TEST_F(FeedbackDialogTest, NonEmptyTextMakesValid) {
    FeedbackDialog dialog;
    auto* textEdit = dialog.findChild<QTextEdit*>();
    ASSERT_NE(textEdit, nullptr);
    textEdit->setPlainText("Bug report");
    EXPECT_TRUE(dialog.isValid());
}

TEST_F(FeedbackDialogTest, WhitespaceOnlyIsInvalid) {
    FeedbackDialog dialog;
    auto* textEdit = dialog.findChild<QTextEdit*>();
    ASSERT_NE(textEdit, nullptr);
    textEdit->setPlainText("   ");
    EXPECT_FALSE(dialog.isValid());
}

TEST_F(FeedbackDialogTest, AllTypesAreAvailable) {
    FeedbackDialog dialog;
    auto* combo = dialog.findChild<QComboBox*>();
    ASSERT_NE(combo, nullptr);
    EXPECT_GE(combo->count(), 2);
}

TEST_F(FeedbackDialogTest, TypeChangePersists) {
    FeedbackDialog dialog;
    auto* combo = dialog.findChild<QComboBox*>();
    ASSERT_NE(combo, nullptr);
    ASSERT_GE(combo->count(), 2);
    QString originalType = dialog.feedbackType();
    combo->setCurrentIndex(1);
    EXPECT_NE(dialog.feedbackType(), originalType);
}

TEST_F(FeedbackDialogTest, EmailWithValueReturnsValue) {
    FeedbackDialog dialog;
    auto* emailEdit = dialog.findChild<QLineEdit*>();
    ASSERT_NE(emailEdit, nullptr);
    emailEdit->setText("user@example.com");
    EXPECT_EQ(dialog.email(), "user@example.com");
}

TEST_F(FeedbackDialogTest, AcceptWithTextEmitsSignal) {
    FeedbackDialog dialog;
    auto* textEdit = dialog.findChild<QTextEdit*>();
    ASSERT_NE(textEdit, nullptr);
    textEdit->setPlainText("Valid feedback text");

    QSignalSpy spy(&dialog, &FeedbackDialog::feedbackSubmitted);
    ASSERT_TRUE(spy.isValid());

    dialog.accept();
    EXPECT_EQ(spy.count(), 1);
    ASSERT_FALSE(spy.isEmpty());
    QList<QVariant> args = spy.takeFirst();
    EXPECT_FALSE(args.at(0).toString().isEmpty()); // type
    EXPECT_EQ(args.at(1).toString(), "Valid feedback text"); // text
}

TEST_F(FeedbackDialogTest, SendButtonDisabledWhenEmpty) {
    FeedbackDialog dialog;
    auto* buttonBox = dialog.findChild<QDialogButtonBox*>();
    ASSERT_NE(buttonBox, nullptr);
    QPushButton* okButton = buttonBox->button(QDialogButtonBox::Ok);
    if (okButton) {
        // With empty text, the OK/Send button should be disabled
        EXPECT_FALSE(okButton->isEnabled());
    }
}

TEST_F(FeedbackDialogTest, CancelDoesNotEmitSubmittedSignal) {
    FeedbackDialog dialog;
    QSignalSpy spy(&dialog, &FeedbackDialog::feedbackSubmitted);
    ASSERT_TRUE(spy.isValid());
    dialog.reject();
    EXPECT_EQ(spy.count(), 0);
}

TEST_F(FeedbackDialogTest, FeedbackTextReturnsSetText) {
    FeedbackDialog dialog;
    auto* textEdit = dialog.findChild<QTextEdit*>();
    ASSERT_NE(textEdit, nullptr);
    textEdit->setPlainText("test text");
    EXPECT_EQ(dialog.feedbackText(), "test text");
}

TEST_F(FeedbackDialogTest, MultipleAcceptsWithoutTextNoSignal) {
    FeedbackDialog dialog;
    QSignalSpy spy(&dialog, &FeedbackDialog::feedbackSubmitted);
    ASSERT_TRUE(spy.isValid());
    dialog.accept();
    dialog.accept();
    EXPECT_EQ(spy.count(), 0);
}

} // namespace test
} // namespace jules

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
