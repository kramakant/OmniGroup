// Copyright 2010-2013 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OUIServerAccountSetupViewController.h"

#import <OmniDAV/ODAVErrors.h> // For OFSShouldOfferToReportError()
#import <OmniFileExchange/OFXServerAccount.h>
#import <OmniFileExchange/OFXServerAccountType.h>
#import <OmniFileExchange/OFXServerAccountRegistry.h>
#import <OmniFoundation/NSMutableDictionary-OFExtensions.h>
#import <OmniFoundation/NSRegularExpression-OFExtensions.h>
#import <OmniFoundation/NSURL-OFExtensions.h>
#import <OmniFoundation/OFCredentials.h>
#import <OmniUI/OUIAlert.h>
#import <OmniUI/OUIAppController.h>
#import <OmniUI/OUIEditableLabeledTableViewCell.h>
#import <OmniUI/OUIEditableLabeledValueCell.h>
#import <OmniUIDocument/OUIDocumentAppController.h>
#import <OmniUI/OUIAppearance.h>

#import "OUIServerAccountValidationViewController.h"

RCS_ID("$Id$")

static const CGFloat TableViewIndent = 15;

@interface OUIServerAccountSetupViewControllerSectionLabel : UILabel
@end

@implementation OUIServerAccountSetupViewControllerSectionLabel
- (void)drawTextInRect:(CGRect)rect;
{
    // Would be less lame to make containing UIView with a label inset from the edges so that UITableView could set the frame of our view as it wishes w/o this hack.
    rect.origin.x += TableViewIndent;
    rect.size.width -= TableViewIndent;
    
    [super drawTextInRect:rect];
}

@end

typedef enum {
    ServerAccountAddressSection,
    ServerAccountCredentialsSection,
    ServerAccountDescriptionSection,
    ServerAccountCloudSyncEnabledSection,
    ServerAccountSectionCount,
} ServerAccountSections;
typedef enum {
    ServerAccountTypeOmniPresence,
    ServerAccountTypeImportExport,
    ServerAccountTypeBoth,
    ServerAccountTypeOptionsCount
} ServerAccountTypeOptions;
typedef enum {
    ServerAccountCredentialsUsernameRow,
    ServerAccountCredentialsPasswordRow,
    ServerAccountCredentialsCount,
} ServerAccountCredentialRows;

#define CELL_AT(section,row) ((OUIEditableLabeledTableViewCell *)[_tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]])
#define TEXT_AT(section,row) [self _textAtSection:section andRow:row]

@interface OUIServerAccountSetupViewController () <OUIEditableLabeledValueCellDelegate, UITableViewDataSource, UITableViewDelegate, MFMailComposeViewControllerDelegate>

@property (nonatomic,assign) BOOL isCloudSyncEnabled;
@property (nonatomic,assign) BOOL isImportExportEnabled;

@end


@implementation OUIServerAccountSetupViewController
{
    UITableView *_tableView;
    OFXServerAccountType *_accountType;
    UIButton *_accountInfoButton;
    NSMutableDictionary *_cachedTextValues;
}

- init;
{
    OBRejectUnusedImplementation(self, _cmd);
    return nil;
}

- (id)initWithAccount:(OFXServerAccount *)account ofType:(OFXServerAccountType *)accountType;
{
    OBPRECONDITION(accountType);
    OBPRECONDITION(!account || account.type == accountType);

    if (!(self = [self initWithNibName:nil bundle:nil]))
        return nil;
    
    _cachedTextValues = [[NSMutableDictionary alloc] init];
    
    _account = account;
    _accountType = accountType;

    NSURLCredential *credential = OFReadCredentialsForServiceIdentifier(_account.credentialServiceIdentifier, NULL);

    self.location = [_account.remoteBaseURL absoluteString];
    self.accountName = credential.user;
    self.password = credential.password;
    self.nickname = _account.nickname;
    self.isCloudSyncEnabled = _account.isCloudSyncEnabled;
    self.isImportExportEnabled = _account.isImportExportEnabled;
        
    if ((self.isCloudSyncEnabled == NO) && (self.isImportExportEnabled == NO)) {
        self.isCloudSyncEnabled = YES; // Default to OmniPresence account for new accounts.
    }

    return self;
}

- (NSString *)_textAtSection:(NSUInteger)section andRow:(NSUInteger)row;
{
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
    return [_cachedTextValues objectForKey:path];
}


#pragma mark - Actions

- (void)saveSettingsAndSync:(id)sender;
{
    NSString *nickname = TEXT_AT(ServerAccountDescriptionSection, 0);
    
    NSURL *serverURL = nil;
    if (_accountType.requiresServerURL)
        serverURL = [OFXServerAccount signinURLFromWebDAVString:TEXT_AT(ServerAccountAddressSection, 0)];
                     
    NSString *username = nil;
    if (_accountType.requiresUsername)
        username = TEXT_AT(ServerAccountCredentialsSection, ServerAccountCredentialsUsernameRow);
    
    NSString *password = nil;
    if (_accountType.requiresPassword)
        password = TEXT_AT(ServerAccountCredentialsSection, ServerAccountCredentialsPasswordRow);

    if (_account != nil) {
        // Some combinations of options require a new account
        BOOL needNewAccount = (self.isCloudSyncEnabled != _account.isCloudSyncEnabled);

        NSURL *newRemoteBaseURL = OFURLWithTrailingSlash([_accountType baseURLForServerURL:serverURL username:username]);
        if (OFNOTEQUAL(newRemoteBaseURL, _account.remoteBaseURL))
            needNewAccount = YES;

        if (needNewAccount) {
            // We need to create a new account to enable cloud sync
            OFXServerAccount *oldAccount = _account;
            _account = nil;
            void (^oldFinished)(id viewController, NSError *errorOrNil) = self.finished;
            self.finished = ^(id viewController, NSError *errorOrNil) {
                if (errorOrNil != nil) {
                    // Pass along the error to our finished call
                    oldFinished(viewController, errorOrNil);
                } else {
                    // Success! Remove the old account.
                    [[OUIDocumentAppController controller] warnAboutDiscardingUnsyncedEditsInAccount:oldAccount withCancelAction:^{
                        oldFinished(viewController, nil);
                    } discardAction:^{
                        [oldAccount prepareForRemoval];
                        oldFinished(viewController, nil); // Go ahead and discard unsynced edits
                    }];
                }
            };
        }
    }

    // Remember if this is a new account or if we are changing the configuration on an existing one.
    BOOL needValidation;
    if (_account == nil) {
        NSURL *remoteBaseURL = OFURLWithTrailingSlash([_accountType baseURLForServerURL:serverURL username:username]);
        
        __autoreleasing NSError *error = nil;
        NSURL *documentsURL = [OFXServerAccount generateLocalDocumentsURLForNewAccount:&error];
        if (documentsURL == nil) {
            [self finishWithError:error];
            OUI_PRESENT_ALERT(error);
            return;
        }
        
        _account = [[OFXServerAccount alloc] initWithType:_accountType remoteBaseURL:remoteBaseURL localDocumentsURL:documentsURL error:&error]; // New account instead of editing one.
        if (!_account) {
            [self finishWithError:error];
            OUI_PRESENT_ALERT(error);
            return;
        }
        
        _account.isCloudSyncEnabled = self.isCloudSyncEnabled;
        needValidation = YES;
    } else {
        NSURLCredential *credential = nil;
        if (_account.credentialServiceIdentifier)
            credential = OFReadCredentialsForServiceIdentifier(_account.credentialServiceIdentifier, NULL);
        
        if (_accountType.requiresServerURL && OFNOTEQUAL(serverURL, _account.remoteBaseURL)) {
            needValidation = YES;
        } else if (_accountType.requiresUsername && OFNOTEQUAL(username, credential.user)) {
            needValidation = YES;
        } else if (_accountType.requiresPassword && OFNOTEQUAL(password, credential.password)) {
            needValidation = YES;
        } else {
            // isCloudSyncEnabled required a whole new account, so we don't need to test it
            needValidation = NO;
        }
    }

    _account.isImportExportEnabled = self.isImportExportEnabled;
    
    // Let us rename existing accounts even if their credentials aren't currently valid
    _account.nickname = nickname;
    if (!needValidation) {
        [self finishWithError:nil];
        return;
    }

    // Validate the new account settings
    OBASSERT(_account.isCloudSyncEnabled == self.isCloudSyncEnabled); // If this changed, we created a new _account with it set properly

    OUIServerAccountValidationViewController *validationViewController = [[OUIServerAccountValidationViewController alloc] initWithAccount:_account username:username password:password];

    validationViewController.finished = ^(OUIServerAccountValidationViewController *vc, NSError *errorOrNil){
        if (errorOrNil != nil) {
            _account = nil; // Make a new instance if this one failed and wasn't added to the registry
            [self.navigationController popToViewController:self animated:YES];
            
            if (![errorOrNil causedByUserCancelling]) {
                [[OUIDocumentAppController controller] presentSyncError:errorOrNil inViewController:self.navigationController retryBlock:NULL];
            }
        } else
            [self finishWithError:errorOrNil];
    };
    [self.navigationController pushViewController:validationViewController animated:YES];
}

#pragma mark - UIViewController subclass

- (void)loadView;
{
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    
    _tableView.scrollEnabled = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone;
//    _tableView.backgroundColor = [UIColor clearColor];
//    _tableView.backgroundView = nil;

    self.view = _tableView;
}

- (void)viewDidLoad;
{
    [super viewDidLoad];
    
    [_tableView reloadData];
    
    if (self.navigationController.viewControllers[0] == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(_cancel:)];
    }
    
    NSString *syncButtonTitle = NSLocalizedStringFromTableInBundle(@"Connect", @"OmniUIDocument", OMNI_BUNDLE, @"Account setup toolbar button title to save account settings");
    UIBarButtonItem *syncBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:syncButtonTitle style:UIBarButtonItemStyleDone target:self action:@selector(saveSettingsAndSync:)];
    self.navigationItem.rightBarButtonItem = syncBarButtonItem;
    
    self.navigationItem.title = _accountType.setUpAccountTitle;
    
    [self _validateSignInButton];
}

- (void)viewWillAppear:(BOOL)animated;
{
    [super viewWillAppear:animated];
    
    OBFinishPortingLater("This isn't reliable -- it works in the WebDAV case, but not OSS, for whatever reason (likely because our UITableView isn't in the window yet");
    [_tableView layoutIfNeeded];
    
#ifdef DEBUG_bungi
    // Speedy account creation
    if (_account == nil) {
        CELL_AT(ServerAccountAddressSection, 0).editableValueCell.valueField.text = @"https://crispix.local:8001/test";
        CELL_AT(ServerAccountCredentialsSection, ServerAccountCredentialsUsernameRow).editableValueCell.valueField.text = @"test";
        CELL_AT(ServerAccountCredentialsSection, ServerAccountCredentialsPasswordRow).editableValueCell.valueField.text = @"password";
    }
#endif

    [self _validateSignInButton];
}

- (void)viewDidAppear:(BOOL)animated;
{
    if (_accountType.requiresServerURL && [NSString isEmptyString:self.location])
        [CELL_AT(ServerAccountAddressSection, 0).editableValueCell.valueField becomeFirstResponder];
    else if (_accountType.requiresUsername && [NSString isEmptyString:self.accountName])
        [CELL_AT(ServerAccountCredentialsSection, ServerAccountCredentialsUsernameRow).editableValueCell.valueField becomeFirstResponder];
    else if (_accountType.requiresPassword && [NSString isEmptyString:self.password])
        [CELL_AT(ServerAccountCredentialsSection, ServerAccountCredentialsPasswordRow).editableValueCell.valueField becomeFirstResponder];
}

- (BOOL)shouldAutorotate;
{
    return YES;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView;
{
    return ServerAccountSectionCount;
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section;
{
    switch (section) {
        case ServerAccountDescriptionSection:
            return 1;
        case ServerAccountAddressSection:
            return _accountType.requiresServerURL ? 1 : 0;
        case ServerAccountCredentialsSection:
            OBASSERT(_accountType.requiresUsername);
            OBASSERT(_accountType.requiresPassword);
            return 2;
        case ServerAccountCloudSyncEnabledSection:
            return ServerAccountTypeOptionsCount;
        default:
            OBASSERT_NOT_REACHED("Unknown section");
            return 0;
    }
}

- (NSString *)_suggestedNickname;
{
    NSURL *url = [OFXServerAccount signinURLFromWebDAVString:TEXT_AT(ServerAccountAddressSection, 0)];
    NSString *username = TEXT_AT(ServerAccountCredentialsSection, ServerAccountCredentialsUsernameRow);
    return [OFXServerAccount suggestedDisplayNameForAccountType:_accountType url:url username:username excludingAccount:_account];

#if 0
    if (_accountType.requiresServerURL) {
        NSURL *locationURL = [OFXServerAccount signinURLFromWebDAVString:TEXT_AT(ServerAccountAddressSection, 0)];
        if (locationURL != nil)
            return [locationURL host];
    }

    return _accountType.displayName;
#endif
}

// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath;
{
    if (indexPath.section == ServerAccountCloudSyncEnabledSection) {
        static NSString * const accountTypeIdentifier = @"OUIServerAccountTypeIdentifier";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:accountTypeIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:accountTypeIdentifier];
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            cell.textLabel.font = [OUIEditableLabeledValueCell labelFont];
        }

        switch (indexPath.row) {
            case ServerAccountTypeOmniPresence:
                cell.textLabel.text = NSLocalizedStringFromTableInBundle(@"OmniPresence", @"OmniUIDocument", OMNI_BUNDLE, @"for WebDAV OmniPresence edit field");
                cell.accessoryType = (self.isCloudSyncEnabled == YES && self.isImportExportEnabled == NO) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone ;
                break;
            case ServerAccountTypeImportExport:
                cell.textLabel.text = NSLocalizedStringFromTableInBundle(@"Import/Export", @"OmniUIDocument", OMNI_BUNDLE, @"for WebDAV Import/Export account type");
                cell.accessoryType = (self.isCloudSyncEnabled == NO && self.isImportExportEnabled == YES) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone ;
                break;
            case ServerAccountTypeBoth:
                cell.textLabel.text = NSLocalizedStringFromTableInBundle(@"Both", @"OmniUIDocument", OMNI_BUNDLE, @"for WebDAV Both (Import and Export) account type");
                cell.accessoryType = (self.isCloudSyncEnabled == YES && self.isImportExportEnabled == YES) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone ;
                break;
            default:
                OBASSERT_NOT_REACHED("Unknown account type.");
                break;
        }
        
        return cell;
    }

    static NSString * const CellIdentifier = @"Cell";
    
    OUIEditableLabeledTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[OUIEditableLabeledTableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        OUIEditableLabeledValueCell *contents = cell.editableValueCell;
        contents.valueField.autocorrectionType = UITextAutocorrectionTypeNo;
        contents.valueField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        contents.delegate = self;
        
        contents.valueField.returnKeyType = UIReturnKeyGo;
        contents.valueField.enablesReturnKeyAutomatically = YES;
    }
    
    OUIEditableLabeledValueCell *contents = cell.editableValueCell;

    NSInteger section = indexPath.section;
    NSString *localizedLocationLabelString = NSLocalizedStringFromTableInBundle(@"Location", @"OmniUIDocument", OMNI_BUNDLE, @"Server Account Setup label: location");
    NSString *localizedNicknameLabelString = NSLocalizedStringFromTableInBundle(@"Nickname", @"OmniUIDocument", OMNI_BUNDLE, @"Server Account Setup label: nickname");
    NSString *localizedUsernameLabelString = NSLocalizedStringFromTableInBundle(@"Account Name", @"OmniUIDocument", OMNI_BUNDLE, @"Server Account Setup label: account name");
    NSString *localizedPasswordLabelString = NSLocalizedStringFromTableInBundle(@"Password", @"OmniUIDocument", OMNI_BUNDLE, @"Server Account Setup label: password");
    
    NSDictionary *attributes = @{NSFontAttributeName: [OUIEditableLabeledValueCell labelFont]};

    static CGFloat minWidth = 0.0f;

    if (minWidth == 0.0f) {
        // Lame... should really use the UITextField's width, not NSStringDrawing
        CGSize locationLabelSize = [localizedLocationLabelString sizeWithAttributes:attributes];
        CGSize usernameLabelSize = [localizedUsernameLabelString sizeWithAttributes:attributes];
        CGSize passwordLabelSize = [localizedPasswordLabelString sizeWithAttributes:attributes];
        CGSize nicknameLabelSize = [localizedNicknameLabelString sizeWithAttributes:attributes];
        minWidth = ceil(4 + MAX(locationLabelSize.width, MAX(usernameLabelSize.width, MAX(passwordLabelSize.width, nicknameLabelSize.width))));
    }

    switch (section) {
        case ServerAccountDescriptionSection:
            contents.label = localizedNicknameLabelString;
            contents.value = self.nickname;
            contents.valueField.placeholder = [self _suggestedNickname];
            contents.valueField.keyboardType = UIKeyboardTypeDefault;
            contents.valueField.secureTextEntry = NO;
            contents.minimumLabelWidth = minWidth;
            contents.labelAlignment = NSTextAlignmentRight;
            break;

        case ServerAccountAddressSection:
            contents.label = localizedLocationLabelString;
            contents.value = self.location;
            contents.valueField.placeholder = @"https://example.com/account/";
            contents.valueField.keyboardType = UIKeyboardTypeURL;
            contents.valueField.secureTextEntry = NO;
            contents.minimumLabelWidth = minWidth;
            contents.labelAlignment = NSTextAlignmentRight;
            break;

        case ServerAccountCredentialsSection: {
            
            switch (indexPath.row) {
                case ServerAccountCredentialsUsernameRow:
                    contents.label = localizedUsernameLabelString;
                    contents.value = self.accountName;
                    contents.valueField.placeholder = nil;
                    contents.valueField.keyboardType = UIKeyboardTypeDefault;
                    contents.valueField.secureTextEntry = NO;
                    contents.minimumLabelWidth = minWidth;
                    contents.labelAlignment = NSTextAlignmentRight;
                    break;
                    
                case ServerAccountCredentialsPasswordRow:
                    contents.label = localizedPasswordLabelString;
                    contents.value = self.password;
                    contents.valueField.placeholder = nil;
                    contents.valueField.secureTextEntry = YES;
                    contents.valueField.keyboardType = UIKeyboardTypeDefault;
                    contents.minimumLabelWidth = minWidth;
                    contents.labelAlignment = NSTextAlignmentRight;
                    break;
                    
                default:
                    OBASSERT_NOT_REACHED("Unknown credential row");
                    break;
            }
            break;
        }
        case ServerAccountSectionCount:
            break;
        default:
            OBASSERT_NOT_REACHED("Unknown section");
            break;
    }
    
    NSString *_cachedValue = [_cachedTextValues objectForKey:indexPath];
    if (_cachedValue)
        contents.value = _cachedValue;
    else if (contents.value)
        [_cachedTextValues setObject:contents.value forKey:indexPath];
    else
        [_cachedTextValues removeObjectForKey:indexPath];
    return cell;
}

static const CGFloat OUIOmniSyncServerSetupHeaderHeight = 44;
static const CGFloat OUIServerAccountSetupViewControllerHeaderHeight = 40;
static const CGFloat OUIServerAccountSendSettingsFooterHeight = 120;

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section;
{
    if (section == ServerAccountCredentialsSection && [_accountType.identifier isEqualToString:OFXOmniSyncServerAccountTypeIdentifier]) {
        UIView *headerView = [[UIView alloc] initWithFrame:(CGRect){
            .origin.x = 0,
            .origin.y = 0,
            .size.width = 0, // Width will automatically be same as the table view it's put into.
            .size.height = OUIOmniSyncServerSetupHeaderHeight
        }];
        
        // Account Info Button
        _accountInfoButton = [UIButton buttonWithType:UIButtonTypeSystem];

        _accountInfoButton.titleLabel.font = [UIFont systemFontOfSize:17];
        [_accountInfoButton addTarget:self action:@selector(accountInfoButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_accountInfoButton setTitle:NSLocalizedStringFromTableInBundle(@"Sign Up For a New Account", @"OmniUIDocument", OMNI_BUNDLE, @"Omni Sync Server sign up button title")
                            forState:UIControlStateNormal];
        [_accountInfoButton sizeToFit];
        
        CGRect frame = _accountInfoButton.frame;
        frame.origin.x = TableViewIndent;
        frame.origin.y = OUIOmniSyncServerSetupHeaderHeight - 44;
        _accountInfoButton.frame = frame;
        
        [headerView addSubview:_accountInfoButton];

#if 0
        // Message Label
        UILabel *messageLabel = [self _sectionLabelWithFrame:(CGRect){
            .origin.x = 0,
            .origin.y = _accountInfoButton.frame.origin.y - 40 /* my height */ - 10.0 /* padding at the bottom */,
            .size.width = tableView.bounds.size.width,
            .size.height = 40
        }];
        
        messageLabel.text = NSLocalizedStringFromTableInBundle(@"Easily sync Omni documents between devices. Signup is free!", @"OmniUIDocument", OMNI_BUNDLE, @"omni sync server setup help");
        [headerView addSubview:messageLabel];
#endif
        return headerView;
    }

    if (section == ServerAccountAddressSection && _accountType.requiresServerURL) {
        UILabel *header = [self _sectionLabelWithFrame:CGRectMake(TableViewIndent, 0, tableView.bounds.size.width - TableViewIndent, OUIServerAccountSetupViewControllerHeaderHeight)];
        header.text = NSLocalizedStringFromTableInBundle(@"Enter the location of your WebDAV space.", @"OmniUIDocument", OMNI_BUNDLE, @"webdav help");
        return header;
    }
    
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if (section == ServerAccountCredentialsSection && [_accountType.identifier isEqualToString:OFXOmniSyncServerAccountTypeIdentifier])
        return OUIOmniSyncServerSetupHeaderHeight + tableView.sectionHeaderHeight;

    if (section == ServerAccountAddressSection && _accountType.requiresServerURL) 
        return OUIServerAccountSetupViewControllerHeaderHeight;
    
    return tableView.sectionHeaderHeight;
}


- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section;
{
    if (section == ServerAccountCloudSyncEnabledSection) {
        CGFloat height = OUIServerAccountSendSettingsFooterHeight;
        CGFloat messageHeight = 40.0;
        
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) { // add space to scroll up with keyboard showing
            height += 220;
            messageHeight = 60.0;
        }
        
        UIView *footerView = [[UIView alloc] initWithFrame:(CGRect){
            .origin.x = 0,
            .origin.y = 0,
            .size.width = 0, // Width will automatically be same as the table view it's put into.
            .size.height = height
        }];
        
        
        
        UILabel *messageLabel = [self _sectionLabelWithFrame:(CGRect) {
            .origin.x = 0,
            .origin.y = 10,
            .size.width = (tableView.frame.size.width),
            .size.height = messageHeight
        }];
        
        messageLabel.text = NSLocalizedStringFromTableInBundle(@"OmniPresence automatically keeps your documents up to date on all of your iPads and Macs.", @"OmniUIDocument", OMNI_BUNDLE, @"omni sync server nickname help");
        
        [footerView addSubview:messageLabel];
        
        // Send Settings Button
        if ([MFMailComposeViewController canSendMail]) {
            OFXServerAccountRegistry *serverAccountRegistry = [OFXServerAccountRegistry defaultAccountRegistry];
            BOOL shouldEnableSettingsButton = [serverAccountRegistry.validCloudSyncAccounts containsObject:self.account] || [serverAccountRegistry.validImportExportAccounts containsObject:self.account];
            
            UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
            settingsButton.titleLabel.font = [UIFont systemFontOfSize:17];
            settingsButton.enabled = shouldEnableSettingsButton;
            
            [settingsButton addTarget:self action:@selector(sendSettingsButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
            [settingsButton setTitle:NSLocalizedStringFromTableInBundle(@"Send Settings via Email", @"OmniUIDocument", OMNI_BUNDLE, @"Omni Sync Server send settings button title")
                                forState:UIControlStateNormal];
            [settingsButton sizeToFit];
            
            CGRect frame = settingsButton.frame;
            frame.origin.x = TableViewIndent;
            frame.origin.y = OUIServerAccountSendSettingsFooterHeight - 44;
            settingsButton.frame = frame;
            
            [footerView addSubview:settingsButton];
        }
        
        
        return footerView;
    }
    
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    if (section == ServerAccountCloudSyncEnabledSection) {
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) // add space to scroll up with keyboard showing
            return OUIServerAccountSendSettingsFooterHeight + 220;
        return OUIServerAccountSendSettingsFooterHeight;
    }
    return tableView.sectionFooterHeight;
}

#pragma mark - UITableViewDelelgate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
{
    if (indexPath.section != ServerAccountCloudSyncEnabledSection) {
        return;
    }
    
    switch (indexPath.row) {
        case ServerAccountTypeOmniPresence:
            self.isCloudSyncEnabled = YES;
            self.isImportExportEnabled = NO;
            break;
        case ServerAccountTypeImportExport:
            self.isCloudSyncEnabled = NO;
            self.isImportExportEnabled = YES;
            break;
        case ServerAccountTypeBoth:
            self.isCloudSyncEnabled = YES;
            self.isImportExportEnabled = YES;
            break;
        default:
            OBASSERT_NOT_REACHED("Unknown type");
            break;
    }

    for (NSInteger rowIndex = 0; rowIndex < ServerAccountTypeOptionsCount; rowIndex++) {
        NSIndexPath *loopIndexPath = [NSIndexPath indexPathForRow:rowIndex inSection:ServerAccountCloudSyncEnabledSection];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:loopIndexPath];
        
        if (rowIndex == indexPath.row) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
        else {
          cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
    
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark -
#pragma mark OUIEditableLabeledValueCell

- (void)editableLabeledValueCellTextDidChange:(OUIEditableLabeledValueCell *)cell;
{
    UITableViewCell *tableCell = [cell containingTableViewCell];
    NSIndexPath *indexPath = [_tableView indexPathForCell:tableCell];
    if (cell.value)
        [_cachedTextValues setObject:cell.value forKey:indexPath];
    else
        [_cachedTextValues removeObjectForKey:indexPath];
    [self _validateSignInButton];
}

- (BOOL)editableLabeledValueCell:(OUIEditableLabeledValueCell *)cell textFieldShouldReturn:(UITextField *)textField;
{
    UIBarButtonItem *signInButton = self.navigationItem.rightBarButtonItem;
    BOOL trySignIn = signInButton.enabled;
    if (trySignIn)
        [self saveSettingsAndSync:nil];
    
    return trySignIn;
}

#pragma mark - Private

- (void)_cancel:(id)sender;
{
    [self cancel];
}

- (void)_validateSignInButton;
{
    UIBarButtonItem *signInButton = self.navigationItem.rightBarButtonItem;

    BOOL requirementsMet = YES;
    
    if (_accountType.requiresServerURL)
        requirementsMet &= ([OFXServerAccount signinURLFromWebDAVString:TEXT_AT(ServerAccountAddressSection, 0)] != nil);
    
    BOOL hasUsername = ![NSString isEmptyString:TEXT_AT(ServerAccountCredentialsSection, ServerAccountCredentialsUsernameRow)];
    if (_accountType.requiresUsername)
        requirementsMet &= hasUsername;
    
    if (_accountType.requiresPassword)
        requirementsMet &= ![NSString isEmptyString:TEXT_AT(ServerAccountCredentialsSection, ServerAccountCredentialsPasswordRow)];

    signInButton.enabled = requirementsMet;
    CELL_AT(ServerAccountDescriptionSection, 0).editableValueCell.valueField.placeholder = [self _suggestedNickname];

    if ([_accountType.identifier isEqualToString:OFXOmniSyncServerAccountTypeIdentifier]) {
        // Validate Account 'button'
        [_accountInfoButton setTitle:hasUsername ? NSLocalizedStringFromTableInBundle(@"Account Info", @"OmniUIDocument", OMNI_BUNDLE, @"Omni Sync Server account info button title") : NSLocalizedStringFromTableInBundle(@"Sign Up For a New Account", @"OmniUIDocument", OMNI_BUNDLE, @"Omni Sync Server sign up button title")
                            forState:UIControlStateNormal];
        [_accountInfoButton sizeToFit];
    }
}

- (UILabel *)_sectionLabelWithFrame:(CGRect)frame;
{
    OUIServerAccountSetupViewControllerSectionLabel *header = [[OUIServerAccountSetupViewControllerSectionLabel alloc] initWithFrame:frame];
    header.textAlignment = NSTextAlignmentLeft;
    header.font = [UIFont systemFontOfSize:14];
    header.backgroundColor = [UIColor clearColor];
    header.opaque = NO;
    header.textColor = [UIColor omniNeutralDeemphasizedColor];
    header.numberOfLines = 0 /* no limit */;
    
    return header;
}

- (void)accountInfoButtonTapped:(id)sender;
{
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"http://www.omnigroup.com/sync/"]];
}

- (NSString *)_accountName;
{
    NSString *currentNickname = TEXT_AT(ServerAccountDescriptionSection, 0);
    if (![NSString isEmptyString:currentNickname])
        return currentNickname;
    else
        return [self _suggestedNickname];
}

- (void)sendSettingsButtonTapped:(id)sender;
{
    NSMutableDictionary *contents = [NSMutableDictionary dictionary];
    [contents setObject:_accountType.identifier forKey:@"accountType" defaultObject:nil];
    [contents setObject:TEXT_AT(ServerAccountCredentialsSection, ServerAccountCredentialsUsernameRow) forKey:@"accountName" defaultObject:nil];
    // [contents setObject:TEXT_AT(ServerAccountCredentialsSection, ServerAccountCredentialsPasswordRow) forKey:@"password" defaultObject:nil];
    if (_accountType.requiresServerURL)
        [contents setObject:TEXT_AT(ServerAccountAddressSection, 0) forKey:@"location" defaultObject:nil];
    [contents setObject:TEXT_AT(ServerAccountDescriptionSection, 0) forKey:@"nickname" defaultObject:nil];

    NSError *error;
    NSData *configData = [NSPropertyListSerialization dataWithPropertyList:contents format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (!configData) {
        OUI_PRESENT_ALERT(error);
        return;
    }
    
    MFMailComposeViewController *composer = [[MFMailComposeViewController alloc] init];
    composer.mailComposeDelegate = self;
    [composer setSubject:[NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"OmniPresence Configuration: %@", @"OmniUIDocument", OMNI_BUNDLE, @"Omni Presence config email subject format"), [self _accountName]]];
    [composer setMessageBody:NSLocalizedStringFromTableInBundle(@"Open this file on another device to configure OmniPresence there.", @"OmniUIDocument", OMNI_BUNDLE, @"Omni Presence config email body") isHTML:NO];
    [composer addAttachmentData:configData mimeType:@"application/vnd.omnigroup.omnipresence.config" fileName:[[self _accountName] stringByAppendingPathExtension:@"omnipresence-config"]];
    [self presentViewController:composer animated:YES completion:nil];
}

- (void)mailComposeController:(MFMailComposeViewController *)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError *)error;
{
    [self dismissViewControllerAnimated:YES completion:nil];
}


@end

